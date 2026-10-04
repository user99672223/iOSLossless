import Foundation
import CoreVideo
import UIKit
import Combine

struct PixelReading: Equatable {
    var x: Int
    var y: Int
    var yCode: Int
    var cbCode: Int
    var crCode: Int
    var bitDepth: Int
    var source: String
}

/// Reads the 10-bit (or 8-bit) Y/Cb/Cr codes under a pixel of a bi-planar buffer.
func readPixel(_ pb: CVPixelBuffer, x: Int, y: Int, source: String) -> PixelReading? {
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    guard x >= 0, y >= 0, x < w, y < h, CVPixelBufferGetPlaneCount(pb) == 2 else { return nil }
    let fmt = CVPixelBufferGetPixelFormatType(pb)
    let is10 = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
    let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    if is10 {
        let yv = (yp + y * ys).load(fromByteOffset: x * 2, as: UInt16.self) >> 6
        let crow = cp + (y / 2) * cs
        let cb = crow.load(fromByteOffset: (x / 2) * 4, as: UInt16.self) >> 6
        let cr = crow.load(fromByteOffset: (x / 2) * 4 + 2, as: UInt16.self) >> 6
        return PixelReading(x: x, y: y, yCode: Int(yv), cbCode: Int(cb), crCode: Int(cr), bitDepth: 10, source: source)
    } else {
        let yv = (yp + y * ys).load(fromByteOffset: x, as: UInt8.self)
        let crow = cp + (y / 2) * cs
        let cb = crow.load(fromByteOffset: (x / 2) * 2, as: UInt8.self)
        let cr = crow.load(fromByteOffset: (x / 2) * 2 + 1, as: UInt8.self)
        return PixelReading(x: x, y: y, yCode: Int(yv), cbCode: Int(cb), crCode: Int(cr), bitDepth: 8, source: source)
    }
}

/// Single-file player: exact frame stepping/scrubbing, decode-paced or
/// real-time playback with audio, zoom/pan and a pixel inspector.
final class PlayerModel: ObservableObject {
    enum PlaybackPacing: String, CaseIterable, Identifiable {
        case everyFrame, realtime
        var id: String { rawValue }
        var label: String { self == .everyFrame ? "Every frame (slows down if needed)" : "Real time (skips frames if decode is slow)" }
    }

    let info: MediaInfo
    let url: URL
    let renderView = VideoRenderView()
    let hasAudio: Bool

    @Published private(set) var currentIndex: Int64 = 0
    @Published private(set) var currentPtsNs: Int64 = 0
    @Published private(set) var isPlaying = false
    @Published var speed: Double = 1.0 { didSet { if isPlaying { restartPlayback() } } }
    @Published var pacing: PlaybackPacing = .everyFrame { didSet { if isPlaying { restartPlayback() } } }
    @Published var audioEnabled = true { didSet { if isPlaying { restartPlayback() } } }
    @Published private(set) var decodeFps: Double = 0
    @Published private(set) var decodeMs: Double = 0
    @Published private(set) var inspector: PixelReading?
    @Published private(set) var crcErrors = 0
    @Published var params = RenderParams() { didSet { renderView.params = params } }
    @Published private(set) var statusText = ""
    @Published private(set) var audioChannelsLabel = ""

    private let source: FrameSource
    private let audio: AudioPlayer?
    private let decodeQueue = DispatchQueue(label: "com.losslesscam.decode", qos: .userInteractive)
    private var currentFrame: DecodedFrame?
    private var playToken = 0
    private let lock = NSLock()
    private var fpsEMA: Double = 0

    /// Opens the decoders off the main thread, then builds the model (which owns a UIView) on main.
    static func load(url: URL, completion: @escaping (PlayerModel?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = makeFrameSource(url: url) else { DispatchQueue.main.async { completion(nil) }; return }
            let audio = source.info.audioCodec != nil ? AudioPlayer(url: url) : nil
            DispatchQueue.main.async { completion(PlayerModel(source: source, audio: audio, url: url)) }
        }
    }

    /// Must be called on the main thread (creates the Metal view).
    init(source s: FrameSource, audio a: AudioPlayer?, url: URL) {
        source = s
        info = s.info
        self.url = url
        if let a = a {
            audio = a
            hasAudio = true
            audioChannelsLabel = a.ambisonic ? "\(a.channels) ch first-order ambisonics → stereo decode" : "\(a.channels) ch"
        } else {
            audio = nil
            hasAudio = false
            audioChannelsLabel = "no audio"
        }
        renderView.bitDepth = info.bitDepth
        renderView.fullRange = info.fullRange
        renderView.isBT2020 = info.colorMatrix == Int32(LC_COLOR_SPC_BT2020_NCL)
        renderView.configureColor(isHDR: info.isHDR)
        renderView.params = params
        renderView.onParamsChanged = { [weak self] p in DispatchQueue.main.async { self?.params = p } }
        renderView.onInspect = { [weak self] point in self?.inspect(at: point) }
        renderView.onTap = { [weak self] in self?.togglePlay() }
        seek(to: 0)
    }

    deinit { pause() }

    var frameCount: Int64 { info.frameCount }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        playToken += 1
        let token = playToken
        let startIndex = currentIndex >= frameCount - 1 ? 0 : currentIndex
        decodeQueue.async { [self] in self.playLoop(token: token, startIndex: startIndex) }
    }

    func pause() {
        isPlaying = false
        playToken += 1
        audio?.stop()
    }

    private func restartPlayback() {
        pause()
        play()
    }

    func seek(to index: Int64) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        let idx = min(max(index, 0), frameCount - 1)
        decodeQueue.async { [self] in
            if let f = self.decode(idx) { self.show(f) }
        }
    }

    func step(_ delta: Int64) {
        if isPlaying { pause() }
        seek(to: currentIndex + delta)
    }

    // MARK: Decode / present

    private func decode(_ index: Int64) -> DecodedFrame? {
        let t0 = CACurrentMediaTime()
        let f = source.frame(at: index)
        let dt = CACurrentMediaTime() - t0
        let inst = dt > 0 ? 1.0 / dt : 0
        fpsEMA = fpsEMA == 0 ? inst : fpsEMA * 0.9 + inst * 0.1
        let fps = fpsEMA, ms = dt * 1000
        let crc = source.crcErrors
        DispatchQueue.main.async { self.decodeFps = fps; self.decodeMs = ms; self.crcErrors = crc }
        return f
    }

    private func show(_ f: DecodedFrame) {
        lock.lock(); currentFrame = f; lock.unlock()
        renderView.present(frameA: f.pixelBuffer, frameB: nil)
        DispatchQueue.main.async {
            self.currentIndex = f.index
            self.currentPtsNs = f.ptsNs
        }
    }

    private func playLoop(token: Int, startIndex: Int64) {
        let fps = info.fps > 0 ? info.fps : 30
        let useAudio = audioEnabled && hasAudio && pacing == .realtime && abs(speed - 1.0) < 0.01
        if useAudio { audio?.start(at: source.pts(ofFrame: startIndex)) }
        let startWall = CACurrentMediaTime()
        var idx = startIndex
        var lastPresented: Int64 = -1
        while true {
            if playToken != token || !isPlaying { break }
            var target = idx
            if pacing == .realtime {
                var elapsed = (CACurrentMediaTime() - startWall) * speed
                if useAudio, let a = audio?.currentTimeNs() {
                    elapsed = Double(a - source.pts(ofFrame: startIndex)) / 1e9
                }
                target = startIndex + Int64(elapsed * fps)
                if target <= lastPresented { Thread.sleep(forTimeInterval: 0.002); continue }
            }
            if target >= frameCount {
                DispatchQueue.main.async { self.isPlaying = false }
                audio?.stop()
                break
            }
            guard let f = decode(target) else {
                DispatchQueue.main.async { self.isPlaying = false; self.statusText = "Decode ended at frame \(target)" }
                audio?.stop()
                break
            }
            if pacing == .everyFrame {
                // Pace to the nominal frame rate when decode is fast enough; otherwise show every frame as soon as it is ready.
                let due = startWall + Double(f.index - startIndex + 1) / (fps * speed)
                let now = CACurrentMediaTime()
                if due > now { Thread.sleep(forTimeInterval: due - now) }
            }
            show(f)
            lastPresented = f.index
            idx = f.index + 1
        }
    }

    // MARK: Inspector

    private func inspect(at point: CGPoint?) {
        guard let point = point else { DispatchQueue.main.async { self.inspector = nil }; return }
        lock.lock(); let frame = currentFrame; lock.unlock()
        guard let f = frame, let pos = renderView.pixelPosition(for: point) else { return }
        let reading = readPixel(f.pixelBuffer, x: pos.x, y: pos.y, source: "A")
        DispatchQueue.main.async { self.inspector = reading }
    }

    func resetView() {
        params.zoom = 1
        params.pan = .zero
    }
}
