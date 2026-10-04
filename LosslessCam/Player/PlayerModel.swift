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

/// Single-file player: exact frame stepping/scrubbing, timestamp-paced playback
/// (gaps left by dropped frames are held, exactly as the audio track runs),
/// zoom/pan and a pixel inspector.
final class PlayerModel: ObservableObject {
    enum PlaybackPacing: String, CaseIterable, Identifiable {
        /// Wall clock / audio clock drives the timeline; frames are skipped when decode is slow.
        case realtime
        /// Every frame is shown, paced by its own timestamp; slows down when decode is slow.
        case everyFrame
        /// Frames back to back at the nominal rate: gaps left by dropped frames are collapsed.
        case compact
        var id: String { rawValue }
        var label: String {
            switch self {
            case .realtime: return "Real time (audio clock, skips frames if decode is slow)"
            case .everyFrame: return "Every frame, timestamp-paced (slows down if needed)"
            case .compact: return "Compact (frames back to back, gaps collapsed)"
            }
        }
    }

    let info: MediaInfo
    let url: URL
    let renderView = VideoRenderView()
    let hasAudio: Bool
    /// Timeline position of the last frame plus one frame duration.
    let timelineEndNs: Int64

    @Published private(set) var currentIndex: Int64 = 0
    @Published private(set) var currentPtsNs: Int64 = 0
    /// Seconds until the next frame when the current one is followed by a gap (0 = contiguous).
    @Published private(set) var gapAfterCurrentSeconds: Double = 0
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
    private var pendingSeek: Int64?
    private var seekInFlight = false

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
        timelineEndNs = s.pts(ofFrame: max(s.info.frameCount - 1, 0)) + s.info.frameDurationNs
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
        if info.gapCount > 0 {
            statusText = "\(info.gapCount) gap\(info.gapCount == 1 ? "" : "s") in the timeline (≈\(info.missingFrames) frames were dropped during capture); playback holds the last frame across gaps"
        }
        seek(to: 0)
    }

    deinit { pause() }

    var frameCount: Int64 { info.frameCount }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        lock.lock(); playToken += 1; let token = playToken; lock.unlock()
        let startIndex = currentIndex >= frameCount - 1 ? 0 : currentIndex
        decodeQueue.async { [self] in self.playLoop(token: token, startIndex: startIndex) }
    }

    func pause() {
        isPlaying = false
        lock.lock(); playToken += 1; lock.unlock()
        audio?.stop()
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return playToken == token
    }

    /// Sleeps until `due` in short slices so pause/seek take effect at once even across long gaps.
    /// Returns false when playback was stopped meanwhile.
    private func waitUntil(_ due: Double, token: Int) -> Bool {
        while true {
            if !isCurrent(token) { return false }
            let remaining = due - CACurrentMediaTime()
            if remaining <= 0 { return true }
            Thread.sleep(forTimeInterval: min(remaining, 0.02))
        }
    }

    private func restartPlayback() {
        pause()
        play()
    }

    /// Seeks are coalesced: a slider drag produces hundreds of requests, each a full
    /// 4K decode, so only the most recent pending target is decoded.
    func seek(to index: Int64) {
        if isPlaying { pause() }
        let idx = min(max(index, 0), frameCount - 1)
        lock.lock()
        pendingSeek = idx
        if seekInFlight { lock.unlock(); return }
        seekInFlight = true
        lock.unlock()
        decodeQueue.async { [self] in
            while true {
                self.lock.lock()
                guard let target = self.pendingSeek else { self.seekInFlight = false; self.lock.unlock(); return }
                self.pendingSeek = nil
                self.lock.unlock()
                if let f = self.decode(target) { self.show(f) }
            }
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
        var gap: Double = 0
        if f.index + 1 < frameCount {
            let delta = source.pts(ofFrame: f.index + 1) - f.ptsNs
            if delta > info.frameDurationNs * 3 / 2 { gap = Double(delta) / 1e9 }
        }
        DispatchQueue.main.async {
            self.currentIndex = f.index
            self.currentPtsNs = f.ptsNs
            self.gapAfterCurrentSeconds = gap
        }
    }

    /// Index of the last frame whose timestamp is at or before `tNs`.
    private func frameAtOrBefore(_ tNs: Int64) -> Int64 {
        var idx = min(max(source.frameIndex(forPts: tNs), 0), frameCount - 1)
        while idx > 0 && source.pts(ofFrame: idx) > tNs { idx -= 1 }
        return idx
    }

    private func playLoop(token: Int, startIndex: Int64) {
        let fps = info.fps > 0 ? info.fps : 30
        let startPts = source.pts(ofFrame: startIndex)
        let endNs = timelineEndNs
        let useAudio = audioEnabled && hasAudio && pacing == .realtime && abs(speed - 1.0) < 0.01
        if useAudio { audio?.start(at: startPts) }
        let startWall = CACurrentMediaTime()
        var idx = startIndex
        var lastPresented: Int64 = -1
        while true {
            if !isCurrent(token) { break }
            var target = idx
            if pacing == .realtime {
                var elapsedNs = Int64((CACurrentMediaTime() - startWall) * speed * 1e9)
                if useAudio, let a = audio?.currentTimeNs() { elapsedNs = a - startPts }
                let tNs = startPts + elapsedNs
                if tNs >= endNs && lastPresented >= frameCount - 1 {
                    DispatchQueue.main.async { self.isPlaying = false }
                    audio?.stop()
                    break
                }
                target = max(frameAtOrBefore(tNs), startIndex)
                if target <= lastPresented { Thread.sleep(forTimeInterval: 0.002); continue }
                if !isCurrent(token) { break }
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
            switch pacing {
            case .everyFrame:
                // Pace by the frames' own timestamps so gaps are held; falls behind only when decode is slower than real time.
                if !waitUntil(startWall + Double(f.ptsNs - startPts) / 1e9 / speed, token: token) { return }
            case .compact:
                if !waitUntil(startWall + Double(f.index - startIndex) / (fps * speed), token: token) { return }
            case .realtime:
                break
            }
            if !isCurrent(token) { return }
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
