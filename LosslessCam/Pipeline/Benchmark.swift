import Foundation
import CoreVideo
import UIKit

/// Measures how fast each stage-1 codec can take 4K60 (or the current format)
/// on this device, with a worker pool like the real pipeline, including the
/// flash write of the compressed output.
final class BenchmarkRunner: ObservableObject {
    struct Result: Codable, Identifiable, Equatable {
        var id: Int { codec }
        var codec: Int                 // Stage1CodecChoice raw value
        var name: String
        var supported: Bool
        var reason: String?
        var framesPerSecond: Double    // codec-only, all workers
        var framesPerSecondWithIO: Double
        var inputMBps: Double
        var outputMBps: Double
        var compressionRatio: Double
        var sustainsTarget: Bool
        var width: Int
        var height: Int
        var bitDepth: Int
        var targetFps: Int
        var workers: Int
        var date: Date
    }

    @Published private(set) var results: [Result] = []
    @Published private(set) var running = false
    @Published private(set) var status: String = ""
    @Published private(set) var progress: Double = 0
    @Published var recommended: Stage1CodecChoice?

    private let key = "LosslessCam.benchmark.v1"
    private var cancelled = false

    init() { load() }

    func load() {
        if let data = UserDefaults.standard.data(forKey: key), let r = try? JSONDecoder().decode([Result].self, from: data) {
            results = r
            recommended = Self.pick(from: r)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(results) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func pick(from results: [Result]) -> Stage1CodecChoice? {
        let ok = results.filter { $0.supported && $0.sustainsTarget }
        // Fastest sustaining option; ties broken by better compression.
        if let best = ok.max(by: { a, b in
            if abs(a.framesPerSecondWithIO - b.framesPerSecondWithIO) > a.framesPerSecondWithIO * 0.1 { return a.framesPerSecondWithIO < b.framesPerSecondWithIO }
            return a.compressionRatio < b.compressionRatio
        }) {
            return Stage1CodecChoice(rawValue: best.codec)
        }
        if let fastest = results.filter({ $0.supported }).max(by: { $0.framesPerSecondWithIO < $1.framesPerSecondWithIO }) {
            return Stage1CodecChoice(rawValue: fastest.codec)
        }
        return nil
    }

    func cancel() { cancelled = true }

    /// Runs every stage-1 candidate at `width`x`height`, `bytesPerSample`, for `seconds` each.
    func run(width: Int, height: Int, bytesPerSample: Int, targetFps: Int, seconds: Double, sampleFrame: CVPixelBuffer?) {
        guard !running else { return }
        running = true
        cancelled = false
        status = "Preparing test frames…"
        progress = 0
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let out = self.runBlocking(width: width, height: height, bytesPerSample: bytesPerSample, targetFps: targetFps, seconds: seconds, sampleFrame: sampleFrame)
            DispatchQueue.main.async {
                self.results = out
                self.recommended = Self.pick(from: out)
                self.save()
                self.running = false
                self.progress = 1
                self.status = self.cancelled ? "Cancelled" : "Done"
            }
        }
    }

    private func setStatus(_ s: String, _ p: Double) {
        DispatchQueue.main.async { self.status = s; self.progress = p }
    }

    private func runBlocking(width: Int, height: Int, bytesPerSample: Int, targetFps: Int, seconds: Double, sampleFrame: CVPixelBuffer?) -> [Result] {
        let stride = width * bytesPerSample
        let frameBytes = stride * height * 3 / 2
        let frameCount = 6
        // Test frames: real camera content when available, otherwise synthetic camera-like data.
        var frames: [UnsafeMutablePointer<UInt8>] = []
        for i in 0..<frameCount {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: frameBytes)
            var usedCamera = false
            if let pb = sampleFrame, CVPixelBufferGetWidth(pb) == width, CVPixelBufferGetHeight(pb) == height,
               CVPixelBufferGetPlaneCount(pb) == 2 {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                    let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                    _ = lc_pack_biplanar(y.assumingMemoryBound(to: UInt8.self), ys, c.assumingMemoryBound(to: UInt8.self), cs,
                                         Int32(width), Int32(height), Int32(bytesPerSample), p)
                    usedCamera = true
                    // Perturb a little so frames differ (like consecutive camera frames).
                    if i > 0 {
                        let n = frameBytes / 64
                        var seed = UInt32(i) &* 2654435761
                        for _ in 0..<n {
                            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                            let idx = Int(seed % UInt32(frameBytes))
                            p[idx] = p[idx] &+ UInt8(seed & 3)
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            }
            if !usedCamera {
                lc_fill_test_frame(p, stride, p + stride * height, stride, Int32(width), Int32(height), Int32(bytesPerSample), UInt32(i))
            }
            frames.append(p)
        }
        defer { frames.forEach { $0.deallocate() } }

        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        let codecs: [Stage1CodecChoice] = [.lz4, .lz4Shuffle, .ffv1Fast, .utvideo, .raw]
        var results: [Result] = []
        let tmpURL = Recording.documentsDirectory().appendingPathComponent(".benchmark.tmp")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        for (ci, codec) in codecs.enumerated() {
            if cancelled { break }
            setStatus("Benchmarking \(codec.label)…", Double(ci) / Double(codecs.count))
            var r = Result(codec: codec.rawValue, name: codec.label, supported: true, reason: nil, framesPerSecond: 0,
                           framesPerSecondWithIO: 0, inputMBps: 0, outputMBps: 0, compressionRatio: 0, sustainsTarget: false,
                           width: width, height: height, bitDepth: bytesPerSample == 2 ? 10 : 8, targetFps: targetFps,
                           workers: workers, date: Date())
            if lc_stage1_codec_supported(codec.lcCodec, Int32(bytesPerSample)) == 0 {
                r.supported = false
                r.reason = codec == .utvideo && bytesPerSample == 2 ? "FFmpeg's UT Video encoder accepts 8-bit only (no yuv420p10le)" : "Not available in this build"
                results.append(r)
                continue
            }
            var cfg = LCIntermediateConfig()
            cfg.width = Int32(width); cfg.height = Int32(height)
            cfg.bytes_per_sample = Int32(bytesPerSample); cfg.bit_depth = Int32(bytesPerSample == 2 ? 10 : 8)
            cfg.color_primaries = Int32(LC_COLOR_PRI_BT2020); cfg.color_trc = Int32(LC_COLOR_TRC_ARIB_STD_B67)
            cfg.colorspace = Int32(LC_COLOR_SPC_BT2020_NCL); cfg.chroma_location = Int32(LC_CHROMA_LOC_LEFT)
            cfg.fps_num = Int32(targetFps); cfg.fps_den = 1
            cfg.codec = codec.lcCodec

            // Phase 1: codec only.
            let phase1 = measure(cfg: cfg, frames: frames, stride: stride, height: height, workers: workers, seconds: seconds * 0.5, writeTo: nil)
            // Phase 2: codec + flash write through the real intermediate writer.
            let phase2 = measure(cfg: cfg, frames: frames, stride: stride, height: height, workers: workers, seconds: seconds * 0.5, writeTo: tmpURL.path)
            if let e = phase1.error ?? phase2.error {
                r.supported = false
                r.reason = e
            } else {
                r.framesPerSecond = phase1.fps
                r.framesPerSecondWithIO = phase2.fps
                r.inputMBps = phase2.fps * Double(frameBytes) / 1_048_576
                r.outputMBps = phase2.outBytesPerSecond / 1_048_576
                r.compressionRatio = phase2.ratio
                r.sustainsTarget = phase2.fps >= Double(targetFps) * 1.05
            }
            results.append(r)
        }
        return results
    }

    private struct Measurement {
        var fps: Double = 0
        var outBytesPerSecond: Double = 0
        var ratio: Double = 0
        var error: String?
    }

    private func measure(cfg: LCIntermediateConfig, frames: [UnsafeMutablePointer<UInt8>], stride: Int, height: Int,
                         workers: Int, seconds: Double, writeTo path: String?) -> Measurement {
        var cfgVar = cfg
        var err = [CChar](repeating: 0, count: 256)
        var writer: OpaquePointer? = nil
        if let path = path {
            try? FileManager.default.removeItem(atPath: path)
            writer = lc_lci_open(path, &cfgVar, nil, 0, &err, err.count)
            if writer == nil { return Measurement(error: "intermediate writer: \(String(cString: err))") }
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var totalFrames: Int64 = 0
        var totalOut: Int64 = 0
        var totalIn: Int64 = 0
        var errorText: String?
        let rawSize = stride * height * 3 / 2
        let deadline = CACurrentMediaTime() + seconds
        let start = CACurrentMediaTime()
        for w in 0..<workers {
            group.enter()
            let t = Thread {
                defer { group.leave() }
                var e = [CChar](repeating: 0, count: 256)
                var c = cfgVar
                guard let enc = lc_s1_encoder_create(&c, &e, e.count) else {
                    lock.lock(); errorText = String(cString: e); lock.unlock()
                    return
                }
                defer { lc_s1_encoder_destroy(enc) }
                var i = w
                var n: Int64 = 0, outBytes: Int64 = 0
                while CACurrentMediaTime() < deadline {
                    let f = frames[i % frames.count]
                    var out: UnsafePointer<UInt8>? = nil
                    var size: Int = 0
                    let rc = lc_s1_encoder_compress(enc, f, stride, f + stride * height, stride, &out, &size)
                    if rc < 0 { lock.lock(); errorText = "compress failed (\(rc))"; lock.unlock(); break }
                    if let wr = writer, let out = out {
                        let h = lc_hash_bytes(out, min(size, 4096))
                        if lc_lci_append_video(wr, Int64(i), Int64(i) * 16_666_667, h, out, size, rawSize) != 0 {
                            lock.lock(); errorText = "write failed (disk full?)"; lock.unlock(); break
                        }
                    }
                    n += 1
                    outBytes += Int64(size)
                    i += workers
                }
                lock.lock(); totalFrames += n; totalOut += outBytes; totalIn += n * Int64(rawSize); lock.unlock()
            }
            t.qualityOfService = .userInitiated
            t.start()
        }
        group.wait()
        let elapsed = max(CACurrentMediaTime() - start, 0.001)
        if let wr = writer { _ = lc_lci_close(wr); try? FileManager.default.removeItem(atPath: path!) }
        if let e = errorText { return Measurement(error: e) }
        return Measurement(fps: Double(totalFrames) / elapsed, outBytesPerSecond: Double(totalOut) / elapsed,
                           ratio: totalOut > 0 ? Double(totalIn) / Double(totalOut) : 0, error: nil)
    }
}
