import Foundation
import AVFoundation

/// Decodes the FLAC track through libavcodec and plays it with AVAudioEngine.
/// First-order ambisonic (W Y Z X) content is rendered as a basic stereo
/// decode (L = W + kY, R = W - kY); the channel count is reported to the UI.
final class AudioPlayer {
    let sampleRate: Int
    let channels: Int
    let ambisonic: Bool

    private let dec: OpaquePointer
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "com.losslesscam.audioplayer", qos: .userInteractive)
    private let inflight = DispatchSemaphore(value: 6)
    private var token = 0
    private let lock = NSLock()
    private var startPtsNs: Int64 = 0
    private var running = false
    private(set) var reachedEnd = false

    init?(url: URL) {
        var err = [CChar](repeating: 0, count: 256)
        guard let d = lc_decoder_open(url.path, 0, 1, 1, &err, err.count) else { return nil }
        var info = LCMediaInfo()
        lc_decoder_get_info(d, &info)
        guard info.has_audio != 0, info.sample_rate > 0, info.channels > 0 else { lc_decoder_close(d); return nil }
        dec = d
        sampleRate = Int(info.sample_rate)
        channels = Int(info.channels)
        ambisonic = info.audio_ambisonic != 0 || info.channels == 4
        guard let f = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2) else { lc_decoder_close(d); return nil }
        format = f
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    deinit {
        stop()
        engine.stop()
        lc_decoder_close(dec)
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func start(at ptsNs: Int64) {
        stop()
        lock.lock()
        token += 1
        let myToken = token
        running = true
        reachedEnd = false
        startPtsNs = max(ptsNs, 0)
        lock.unlock()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        if !engine.isRunning { try? engine.start() }
        _ = lc_decoder_seek_audio(dec, startPtsNs)
        node.play()
        queue.async { [self] in self.feedLoop(token: myToken) }
    }

    func stop() {
        lock.lock()
        running = false
        token += 1
        lock.unlock()
        node.stop()
        // Release any producer waiting for a slot.
        for _ in 0..<6 { inflight.signal() }
        // Re-arm the semaphore to its nominal capacity.
        queue.sync {
            var n = 0
            while inflight.wait(timeout: .now()) == .success { n += 1 }
            for _ in 0..<6 { inflight.signal() }
        }
    }

    /// Current playback position derived from the audio hardware clock.
    func currentTimeNs() -> Int64? {
        lock.lock(); let r = running; let start = startPtsNs; lock.unlock()
        guard r, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else { return nil }
        return start + Int64(Double(pt.sampleTime) * 1e9 / Double(sampleRate))
    }

    private func feedLoop(token myToken: Int) {
        let chunk = 4096
        var buf = [Int32](repeating: 0, count: chunk * channels)
        while true {
            lock.lock(); let ok = running && token == myToken; lock.unlock()
            if !ok { return }
            inflight.wait()
            lock.lock(); let still = running && token == myToken; lock.unlock()
            if !still { inflight.signal(); return }
            var pts: Int64 = 0
            let n = buf.withUnsafeMutableBufferPointer { p in lc_decoder_next_audio(dec, p.baseAddress, Int32(chunk), &pts) }
            if n <= 0 {
                inflight.signal()
                lock.lock(); reachedEnd = true; lock.unlock()
                return
            }
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { inflight.signal(); return }
            out.frameLength = AVAudioFrameCount(n)
            let l = out.floatChannelData![0], r = out.floatChannelData![1]
            let scale: Float = 1.0 / 2147483648.0
            let k: Float = 0.7071
            for i in 0..<Int(n) {
                let base = i * channels
                if channels == 1 {
                    let v = Float(buf[base]) * scale
                    l[i] = v; r[i] = v
                } else if channels >= 4 && ambisonic {
                    let w = Float(buf[base]) * scale
                    let y = Float(buf[base + 1]) * scale
                    l[i] = (w + k * y) * 0.5
                    r[i] = (w - k * y) * 0.5
                } else {
                    l[i] = Float(buf[base]) * scale
                    r[i] = Float(buf[base + 1]) * scale
                }
            }
            node.scheduleBuffer(out) { [weak self] in self?.inflight.signal() }
        }
    }
}
