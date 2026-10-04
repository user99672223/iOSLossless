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
    private let cond = NSCondition()
    private var inflight = 0
    private let maxInflight = 6
    private var token = 0
    private var startPtsNs: Int64 = 0
    private var running = false
    private(set) var reachedEnd = false

    init?(url: URL) {
        var err = [CChar](repeating: 0, count: 256)
        guard let d = lc_decoder_open(url.path, 0, 1, 1, &err, 256) else { return nil }
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

    var isRunning: Bool { cond.lock(); defer { cond.unlock() }; return running }

    func start(at ptsNs: Int64) {
        stop()
        cond.lock()
        token += 1
        let myToken = token
        running = true
        reachedEnd = false
        startPtsNs = max(ptsNs, 0)
        cond.unlock()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        if !engine.isRunning { try? engine.start() }
        _ = lc_decoder_seek_audio(dec, startPtsNs)
        node.play()
        queue.async { [self] in self.feedLoop(token: myToken) }
    }

    /// Safe to call from any thread, including the feed queue itself.
    func stop() {
        cond.lock()
        running = false
        token += 1
        cond.broadcast()
        cond.unlock()
        node.stop()
    }

    /// Current playback position derived from the audio hardware clock.
    func currentTimeNs() -> Int64? {
        cond.lock(); let r = running; let start = startPtsNs; cond.unlock()
        guard r, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else { return nil }
        return start + Int64(Double(pt.sampleTime) * 1e9 / Double(sampleRate))
    }

    private func feedLoop(token myToken: Int) {
        let chunk = 4096
        var buf = [Int32](repeating: 0, count: chunk * channels)
        while true {
            // Wait for a free slot (bounded number of scheduled buffers).
            cond.lock()
            while running && token == myToken && inflight >= maxInflight { cond.wait() }
            let ok = running && token == myToken
            if ok { inflight += 1 }
            cond.unlock()
            if !ok { return }

            var pts: Int64 = 0
            let n = buf.withUnsafeMutableBufferPointer { p in lc_decoder_next_audio(dec, p.baseAddress, Int32(chunk), &pts) }
            if n <= 0 {
                cond.lock(); inflight -= 1; reachedEnd = true; cond.unlock()
                return
            }
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
                cond.lock(); inflight -= 1; cond.unlock()
                return
            }
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
            node.scheduleBuffer(out) { [weak self] in
                guard let self = self else { return }
                self.cond.lock(); self.inflight -= 1; self.cond.signal(); self.cond.unlock()
            }
        }
    }
}
