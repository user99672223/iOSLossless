import Foundation
import CoreVideo
import UIKit
import Combine

/// Two-source comparison: A (usually the lossless MKV) drives the timeline; B
/// (the HEVC reference or another recording) is matched by presentation time
/// plus a user/auto offset. Luma PSNR/SSIM per frame with running averages.
final class ComparisonModel: ObservableObject {
    struct Metrics: Equatable {
        var psnr: Double = 0
        var ssim: Double = 0
        var mse: Double = 0
        var identical = false
    }

    let infoA: MediaInfo
    let infoB: MediaInfo
    let renderView = VideoRenderView()
    let nameA: String
    let nameB: String

    @Published private(set) var currentIndex: Int64 = 0
    @Published private(set) var currentIndexB: Int64 = 0
    @Published private(set) var currentPtsNs: Int64 = 0
    @Published private(set) var isPlaying = false
    @Published var mode: CompareMode = .sideBySide { didSet { params.mode = mode; renderView.dividerDragEnabled = mode == .wipe } }
    @Published var params = RenderParams(mode: .sideBySide) { didSet { renderView.params = params } }
    @Published var offsetFrames: Int64 = 0 { didSet { if oldValue != offsetFrames { seek(to: currentIndex) } } }
    @Published private(set) var metrics = Metrics()
    @Published private(set) var averagePSNR: Double = 0
    @Published private(set) var averageSSIM: Double = 0
    @Published private(set) var framesMeasured: Int = 0
    @Published private(set) var decodeFps: Double = 0
    @Published private(set) var inspector: PixelReading?
    @Published private(set) var statusText = ""
    @Published private(set) var aligning = false
    @Published var speed: Double = 1.0

    private let a: FrameSource
    private let b: FrameSource
    private let queueA = DispatchQueue(label: "com.losslesscam.decodeA", qos: .userInteractive)
    private let queueB = DispatchQueue(label: "com.losslesscam.decodeB", qos: .userInteractive)
    private let metricsQueue = DispatchQueue(label: "com.losslesscam.metrics", qos: .utility)
    private var frameA: DecodedFrame?
    private var frameB: DecodedFrame?
    private let lock = NSLock()
    private var playToken = 0
    private var psnrSum: Double = 0
    private var ssimSum: Double = 0
    private var measured = 0
    private var fpsEMA: Double = 0

    init?(urlA: URL, urlB: URL) {
        guard let sa = makeFrameSource(url: urlA), let sb = makeFrameSource(url: urlB) else { return nil }
        a = sa; b = sb
        infoA = sa.info; infoB = sb.info
        nameA = urlA.lastPathComponent
        nameB = urlB.lastPathComponent
        renderView.bitDepth = infoA.bitDepth
        renderView.fullRange = infoA.fullRange
        renderView.isBT2020 = infoA.colorMatrix == Int32(LC_COLOR_SPC_BT2020_NCL)
        renderView.configureColor(isHDR: infoA.isHDR)
        renderView.params = params
        renderView.dividerDragEnabled = mode == .wipe
        renderView.onParamsChanged = { [weak self] p in DispatchQueue.main.async { self?.params = p } }
        renderView.onTap = { [weak self] in
            guard let self = self else { return }
            if self.mode == .abFlip { DispatchQueue.main.async { self.params.showB.toggle() } }
        }
        renderView.onHold = { [weak self] down in
            guard let self = self, self.mode == .abFlip else { return }
            DispatchQueue.main.async { self.params.showB = down ? !self.params.showB : self.params.showB }
        }
        renderView.onInspect = { [weak self] p in self?.inspect(at: p) }
        if infoB.bitDepth != infoA.bitDepth || infoB.width != infoA.width || infoB.height != infoA.height {
            statusText = "B is \(infoB.width)×\(infoB.height) \(infoB.bitDepth)-bit; metrics need identical geometry"
        }
        seek(to: 0)
    }

    deinit { pause() }

    var frameCount: Int64 { infoA.frameCount }

    func indexB(forA indexA: Int64) -> Int64 {
        let pts = a.pts(ofFrame: indexA)
        let ib = b.frameIndex(forPts: pts) + offsetFrames
        return min(max(ib, 0), infoB.frameCount - 1)
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        playToken += 1
        let token = playToken
        let start = currentIndex >= frameCount - 1 ? 0 : currentIndex
        queueA.async { [self] in self.playLoop(token: token, start: start) }
    }

    func pause() {
        isPlaying = false
        playToken += 1
    }

    func seek(to index: Int64) {
        if isPlaying { pause() }
        let idx = min(max(index, 0), frameCount - 1)
        queueA.async { [self] in self.decodePair(idx, computeMetrics: true) }
    }

    func step(_ delta: Int64) { seek(to: currentIndex + delta) }

    private func decodePair(_ idx: Int64, computeMetrics: Bool) {
        let t0 = CACurrentMediaTime()
        let ib = indexB(forA: idx)
        var fb: DecodedFrame?
        let group = DispatchGroup()
        group.enter()
        queueB.async { fb = self.b.frame(at: ib); group.leave() }
        let fa = a.frame(at: idx)
        group.wait()
        let dt = CACurrentMediaTime() - t0
        let inst = dt > 0 ? 1 / dt : 0
        fpsEMA = fpsEMA == 0 ? inst : fpsEMA * 0.9 + inst * 0.1
        guard let fa = fa else { return }
        lock.lock(); frameA = fa; frameB = fb; lock.unlock()
        renderView.present(frameA: fa.pixelBuffer, frameB: fb?.pixelBuffer)
        let fps = fpsEMA
        DispatchQueue.main.async {
            self.currentIndex = fa.index
            self.currentIndexB = fb?.index ?? -1
            self.currentPtsNs = fa.ptsNs
            self.decodeFps = fps
        }
        if computeMetrics, let fb = fb { computeMetrics(fa, fb) }
    }

    private func playLoop(token: Int, start: Int64) {
        let fps = infoA.fps > 0 ? infoA.fps : 30
        let startWall = CACurrentMediaTime()
        var idx = start
        while playToken == token && isPlaying {
            if idx >= frameCount { DispatchQueue.main.async { self.isPlaying = false }; break }
            decodePair(idx, computeMetrics: true)
            let due = startWall + Double(idx - start + 1) / (fps * speed)
            let now = CACurrentMediaTime()
            if due > now { Thread.sleep(forTimeInterval: due - now) }
            idx += 1
        }
    }

    // MARK: Metrics

    private func computeMetrics(_ fa: DecodedFrame, _ fb: DecodedFrame) {
        let pa = fa.pixelBuffer, pb = fb.pixelBuffer
        guard CVPixelBufferGetWidth(pa) == CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pa) == CVPixelBufferGetHeight(pb),
              CVPixelBufferGetPixelFormatType(pa) == CVPixelBufferGetPixelFormatType(pb) else { return }
        let bps = infoA.bitDepth == 10 ? 2 : 1
        CVPixelBufferLockBaseAddress(pa, .readOnly)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        var m = LCLumaMetrics()
        var ok = false
        if let ya = CVPixelBufferGetBaseAddressOfPlane(pa, 0), let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            ok = lc_luma_metrics(ya.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(pa, 0),
                                 yb.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                                 Int32(CVPixelBufferGetWidth(pa)), Int32(CVPixelBufferGetHeight(pa)), Int32(bps), 6,
                                 Int32(bps == 2 ? 1023 : 255), &m) == 0
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        CVPixelBufferUnlockBaseAddress(pa, .readOnly)
        guard ok else { return }
        let identical = m.mse == 0
        // Identical frames have infinite PSNR; cap at 99 dB so the running average stays finite.
        psnrSum += identical ? 99.0 : min(m.psnr, 99.0)
        ssimSum += m.ssim
        measured += 1
        let avgP = psnrSum / Double(max(measured, 1)), avgS = ssimSum / Double(max(measured, 1)), n = measured
        let metrics = Metrics(psnr: m.psnr, ssim: m.ssim, mse: m.mse, identical: identical)
        DispatchQueue.main.async {
            self.metrics = metrics
            self.averagePSNR = avgP
            self.averageSSIM = avgS
            self.framesMeasured = n
        }
    }

    func resetAverages() {
        psnrSum = 0; ssimSum = 0; measured = 0
        averagePSNR = 0; averageSSIM = 0; framesMeasured = 0
    }

    /// Searches offsets of ±range frames around the current position for the best PSNR.
    func autoAlign(range: Int64 = 6) {
        guard !aligning else { return }
        aligning = true
        let idx = currentIndex
        let base = offsetFrames
        queueA.async { [self] in
            guard let fa = self.a.frame(at: idx) else { DispatchQueue.main.async { self.aligning = false }; return }
            var best: (offset: Int64, psnr: Double) = (base, -1)
            let pts = self.a.pts(ofFrame: idx)
            let centre = self.b.frameIndex(forPts: pts)
            for off in (-range)...range {
                let ib = centre + off
                guard ib >= 0, ib < self.infoB.frameCount, let fb = self.b.frame(at: ib) else { continue }
                var m = LCLumaMetrics()
                CVPixelBufferLockBaseAddress(fa.pixelBuffer, .readOnly); CVPixelBufferLockBaseAddress(fb.pixelBuffer, .readOnly)
                if let ya = CVPixelBufferGetBaseAddressOfPlane(fa.pixelBuffer, 0), let yb = CVPixelBufferGetBaseAddressOfPlane(fb.pixelBuffer, 0),
                   CVPixelBufferGetWidth(fa.pixelBuffer) == CVPixelBufferGetWidth(fb.pixelBuffer) {
                    let bps = self.infoA.bitDepth == 10 ? 2 : 1
                    _ = lc_luma_metrics(ya.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(fa.pixelBuffer, 0),
                                        yb.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(fb.pixelBuffer, 0),
                                        Int32(CVPixelBufferGetWidth(fa.pixelBuffer)), Int32(CVPixelBufferGetHeight(fa.pixelBuffer)), Int32(bps), 6,
                                        Int32(bps == 2 ? 1023 : 255), &m)
                }
                CVPixelBufferUnlockBaseAddress(fb.pixelBuffer, .readOnly); CVPixelBufferUnlockBaseAddress(fa.pixelBuffer, .readOnly)
                let p = m.mse == 0 ? 999 : m.psnr
                if p > best.psnr { best = (off, p) }
            }
            DispatchQueue.main.async {
                self.aligning = false
                self.statusText = "Auto-align: best offset \(best.offset) frames (PSNR \(best.psnr >= 999 ? "∞" : String(format: "%.2f", best.psnr)) dB)"
                self.offsetFrames = best.offset
            }
        }
    }

    // MARK: Inspector

    private func inspect(at point: CGPoint?) {
        guard let point = point else { DispatchQueue.main.async { self.inspector = nil }; return }
        lock.lock(); let fa = frameA; let fb = frameB; lock.unlock()
        guard let pos = renderView.pixelPosition(for: point) else { return }
        let frame = pos.isB ? fb : fa
        guard let f = frame else { return }
        let reading = readPixel(f.pixelBuffer, x: pos.x, y: pos.y, source: pos.isB ? "B" : "A")
        DispatchQueue.main.async { self.inspector = reading }
    }

    func resetView() {
        params.zoom = 1
        params.pan = .zero
    }
}
