import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

/// Audio sample format as delivered by AVCaptureAudioDataOutput.
struct AudioFormatInfo: Equatable {
    var sampleRate: Int
    var channels: Int
    var source: LCAudioSourceFormat
    var nonInterleaved: Bool
    var bitsPerChannel: Int
    var description: String

    static func detect(_ sb: CMSampleBuffer) -> AudioFormatInfo? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isInt = flags & kAudioFormatFlagIsSignedInteger != 0
        let nonInter = flags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(asbd.mChannelsPerFrame)
        let bits = Int(asbd.mBitsPerChannel)
        guard channels > 0, asbd.mSampleRate > 0 else { return nil }
        let bytesPerSample = nonInter ? Int(asbd.mBytesPerFrame) : Int(asbd.mBytesPerFrame) / max(channels, 1)
        var src: LCAudioSourceFormat
        var desc: String
        if isFloat && bits == 32 {
            src = LC_AUDIO_SRC_FLOAT32; desc = "Float32"
        } else if isInt && bits == 16 {
            src = LC_AUDIO_SRC_INT16; desc = "Int16"
        } else if isInt && bits == 24 && bytesPerSample == 3 {
            src = LC_AUDIO_SRC_INT24; desc = "Int24 packed"
        } else if isInt && bits == 24 && bytesPerSample == 4 {
            let high = flags & kAudioFormatFlagIsAlignedHigh != 0
            src = high ? LC_AUDIO_SRC_INT32 : LC_AUDIO_SRC_INT24_IN_32_LOW
            desc = high ? "Int24 in 32 (high)" : "Int24 in 32 (low)"
        } else if isInt && bits == 32 {
            src = LC_AUDIO_SRC_INT32; desc = "Int32"
        } else {
            return nil
        }
        desc += nonInter ? " non-interleaved" : " interleaved"
        return AudioFormatInfo(sampleRate: Int(asbd.mSampleRate.rounded()), channels: channels, source: src,
                               nonInterleaved: nonInter, bitsPerChannel: bits, description: "\(desc), \(channels) ch, \(Int(asbd.mSampleRate)) Hz")
    }
}

/// Orchestrates one recording: ring buffer, worker pool, stage-1 intermediate
/// or real-time FFV1 writer, audio conversion, hash lists, telemetry and the
/// sidecar metadata. Hands finished two-stage recordings to `Stage2Runner`.
///
/// Timeline model: every accepted frame keeps its AVFoundation presentation
/// timestamp, so a recording whose pipeline could not keep up has the real
/// duration (first to last kept frame) with gaps, never a compressed timeline.
/// Dropped frames are counted, shown live, written to the sidecar and never
/// silent.
final class RecordingPipeline: ObservableObject {
    struct Config {
        var baseName: String
        var width: Int
        var height: Int
        var bytesPerSample: Int
        var fullRange: Bool
        var pixelFormatFourCC: String
        var colour: ColourInfo
        var fps: Int
        var captureMode: CaptureMode
        var stage1Codec: Stage1CodecChoice
        var ffv1: LCFfv1Params
        var flacLevel: Int
        var settings: CaptureSettings
        var referencePath: String
        var deviceModel: String
        /// Whether an audio input is attached (decides how long the first frame waits for the audio format).
        var audioExpected: Bool = true

        var frameBytes: Int { width * height * bytesPerSample * 3 / 2 }
        var bitDepth: Int { bytesPerSample == 2 ? 10 : 8 }
    }

    @Published private(set) var telemetry = Telemetry()
    @Published private(set) var lastMessage: String?
    /// Set when the pipeline had to stop accepting frames (disk full, writer failure). The UI stops the recording.
    @Published private(set) var fatalFailure: String?

    /// Receives every delivered sample buffer so the AVAssetWriter reference path can encode them.
    var referenceSink: ((CMSampleBuffer, Bool) -> Void)?
    /// Most recent camera frame for the benchmark screen (only while not recording; read through `benchmarkSample()`).
    private var latestFrameForBenchmark: CVPixelBuffer?
    private var lastBenchmarkFrameTime: Double = 0

    /// Thread-safe snapshot of the latest preview frame for the benchmark.
    func benchmarkSample() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latestFrameForBenchmark
    }

    // MARK: State (guarded by `lock`)
    private let lock = NSLock()
    private var recording = false
    private var config: Config?
    private var ring: FrameRingBuffer?
    private var writersOpen = false
    private let writersReady = DispatchSemaphore(value: 0)
    private var workerGroup = DispatchGroup()
    private var workerCount = 0

    private var hashList: OpaquePointer?          // LCHashListWriter*
    private var lci: OpaquePointer?               // LCIntermediateWriter*
    private var mkv: OpaquePointer?               // LCMkvWriter*
    private var s1Extradata: [UInt8] = []

    private var audioFormat: AudioFormatInfo?
    /// Whether the writers' headers were opened with an audio stream (audio arriving later cannot be stored).
    private var audioEnabledForTake = false
    private var lateAudioNoted = false
    /// Tracks intermediate-writer appends made outside `lock` so finish() never closes the writer under them.
    private let appendGroup = DispatchGroup()
    private var pendingAudio: [(pts: Int64, samples: [Int32])] = []
    private var audioQueue: [(pts: Int64, samples: [Int32])] = []   // real-time path
    private var audioBuffers: Int64 = 0
    private var audioFrames: Int64 = 0
    private var audioInexact: Int64 = 0
    private var nextAudioCheckpoint: Int64 = 48000
    private var audioFirstPts: Int64 = 0

    private var deliveredFrames: Int64 = 0
    private var acceptedFrames: Int64 = 0
    private var writtenFrames: Int64 = 0
    private var droppedFrames: Int64 = 0
    private var sourceDrops: Int64 = 0
    private var firstVideoPts: Int64 = 0
    private var lastVideoPts: Int64 = 0
    private var firstAcceptedPts: Int64 = -1
    private var lastAcceptedPts: Int64 = -1
    private var firstVideoWall: Double = 0
    private var lowBits: UInt16 = 0
    private var memoryWarnings = 0
    private var peakFill: Double = 0
    private var fpsSamples: [Double] = []
    private var mbpsSamples: [Double] = []
    private var maxThermal = 0
    private var notes: [String] = []
    private var failure: String?

    private var reorder: [Int64: (pts: Int64, hash: UInt64)] = [:]
    private var nextHashIndex: Int64 = 0

    private var writeRate = RateMeter(window: 2.0)
    private var ingestRate = RateMeter(window: 2.0)
    private var dropRate = RateMeter(window: 2.0)
    private var bytesRate = RateMeter(window: 2.0)
    private var lastBytes: Int64 = 0
    private var timer: DispatchSourceTimer?
    private let telemetryQueue = DispatchQueue(label: "com.losslesscam.telemetry", qos: .utility)
    private var memoryObserver: NSObjectProtocol?

    init() {
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }

    deinit { if let o = memoryObserver { NotificationCenter.default.removeObserver(o) } }

    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return recording }

    // MARK: Start

    func start(config: Config) {
        lock.lock()
        self.config = config
        latestFrameForBenchmark = nil   // never hold a camera pool buffer while recording
        recording = true
        writersOpen = false
        deliveredFrames = 0; acceptedFrames = 0; writtenFrames = 0; droppedFrames = 0; sourceDrops = 0
        audioBuffers = 0; audioFrames = 0; audioInexact = 0; nextAudioCheckpoint = 48000
        audioFormat = nil; pendingAudio.removeAll(); audioQueue.removeAll()
        audioEnabledForTake = false; lateAudioNoted = false
        reorder.removeAll(); nextHashIndex = 0
        lowBits = 0; memoryWarnings = 0; peakFill = 0; fpsSamples.removeAll(); mbpsSamples.removeAll(); maxThermal = 0; notes.removeAll()
        failure = nil
        firstVideoPts = 0; lastVideoPts = 0; firstAcceptedPts = -1; lastAcceptedPts = -1; firstVideoWall = 0; lastBytes = 0
        writeRate.reset(); ingestRate.reset(); dropRate.reset(); bytesRate.reset()

        // Ring buffer sized from the memory the kernel will let us use, kept well below
        // the point where iOS starts sending memory warnings (and jetsam follows).
        let avail = availableMemoryBytes()
        let budget = min(Int64(Double(avail) * 0.45), 3 << 30)
        var frames = Int(budget / Int64(max(config.frameBytes, 1)))
        frames = max(6, min(frames, 480))
        ring = FrameRingBuffer(capacity: frames, maxCameraOwned: 2)

        // Workers: one per core for the stage-1 codecs (the capture thread itself does
        // little work); the FFV1 encoder threads internally in real-time mode.
        workerGroup = DispatchGroup()
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if config.captureMode == .twoStage {
            workerCount = max(2, min(cores, 8))
            for i in 0..<workerCount {
                workerGroup.enter()
                let t = Thread { [weak self] in self?.stage1WorkerLoop(index: i) }
                t.name = "stage1-worker-\(i)"
                t.qualityOfService = .userInteractive
                t.stackSize = 1 << 20
                t.start()
            }
        } else {
            workerCount = 1
            workerGroup.enter()
            let t = Thread { [weak self] in self?.realtimeEncodeLoop() }
            t.name = "ffv1-realtime"
            t.qualityOfService = .userInteractive
            t.stackSize = 1 << 20
            t.start()
        }
        lock.unlock()

        var t = Telemetry()
        t.isRecording = true
        t.bufferCapacity = frames
        t.workerCount = workerCount
        t.stage1Codec = config.captureMode == .twoStage ? config.stage1Codec.label : "FFV1 real-time"
        t.availableMemoryBytes = avail
        DispatchQueue.main.async { self.telemetry = t; self.fatalFailure = nil }
        startTelemetryTimer()
    }

    // MARK: Ingest (capture delegate threads)

    func ingestVideo(_ sb: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        if !recording && now - lastBenchmarkFrameTime > 1.0 {
            // Preview only: never hold an extra camera pool buffer while recording.
            lastBenchmarkFrameTime = now
            latestFrameForBenchmark = pb
        }
        guard recording, let cfg = config, let ring = ring else { lock.unlock(); return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let ptsNs = Int64(CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value)
        deliveredFrames += 1
        ingestRate.add(1, at: now)
        if deliveredFrames == 1 {
            firstVideoPts = ptsNs
            firstVideoWall = now
        }
        lastVideoPts = ptsNs

        // Sanity: geometry must match the configured format exactly (no silent conversion).
        if CVPixelBufferGetWidth(pb) != cfg.width || CVPixelBufferGetHeight(pb) != cfg.height {
            droppedFrames += 1
            dropRate.add(1, at: now)
            if notes.count < 20 { notes.append("Frame geometry \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) differs from configured \(cfg.width)x\(cfg.height); frame rejected") }
            lock.unlock()
            return
        }

        if !writersOpen {
            // Wait briefly for the audio format so the headers carry it; otherwise open without audio.
            if audioFormat != nil || !cfg.audioExpected || (now - firstVideoWall) > 0.4 {
                openWritersLocked(firstVideoPts: firstVideoPts)
            }
        }
        let index = acceptedFrames
        lock.unlock()

        referenceSink?(sb, true)

        if ring.push(pixelBuffer: pb, ptsNs: ptsNs, outputIndex: index) {
            lock.lock()
            acceptedFrames += 1
            if firstAcceptedPts < 0 { firstAcceptedPts = ptsNs }
            lastAcceptedPts = ptsNs
            lock.unlock()
        } else {
            lock.lock()
            droppedFrames += 1
            dropRate.add(1, at: now)
            lock.unlock()
        }
    }

    func ingestAudio(_ sb: CMSampleBuffer) {
        lock.lock()
        guard recording else { lock.unlock(); return }
        if audioFormat == nil, let f = AudioFormatInfo.detect(sb) {
            audioFormat = f
        }
        guard let fmt = audioFormat else { lock.unlock(); return }
        lock.unlock()

        referenceSink?(sb, false)

        guard let converted = RecordingPipeline.convert(sb, format: fmt) else { return }
        lock.lock()
        if !recording { lock.unlock(); return }
        if writersOpen && !audioEnabledForTake {
            // The headers were written without an audio stream; later audio cannot be stored.
            if !lateAudioNoted {
                lateAudioNoted = true
                notes.append("Audio started arriving after the recording headers were written (no audio stream in this take)")
            }
            lock.unlock()
            return
        }
        audioBuffers += 1
        audioFrames += Int64(converted.frames)
        audioInexact += converted.inexact
        if audioBuffers == 1 { audioFirstPts = converted.ptsNs }
        if !writersOpen {
            pendingAudio.append((converted.ptsNs, converted.samples))
            if pendingAudio.count > 4000 { pendingAudio.removeFirst(); notes.append("Audio pre-roll buffer overflow") }
            lock.unlock()
            return
        }
        if let lci = lci {
            appendGroup.enter()
            lock.unlock()
            let rc = converted.samples.withUnsafeBufferPointer { p in
                lc_lci_append_audio(lci, converted.ptsNs, p.baseAddress, Int32(converted.frames))
            }
            appendGroup.leave()
            if rc != 0 {
                lock.lock()
                if failure == nil { failLocked("Intermediate audio write failed (storage full?) — recording stopped") }
                lock.unlock()
            }
            return
        }
        // Real-time path: handed to the encode thread, which owns the MKV writer.
        audioQueue.append((converted.ptsNs, converted.samples))
        lock.unlock()
    }

    func noteSourceDrop(reason: String) {
        lock.lock()
        sourceDrops += 1
        if notes.count < 20 && !notes.contains(where: { $0.hasPrefix("Source drop") }) {
            notes.append("Source drop reason: \(reason)")
        }
        lock.unlock()
    }

    struct ConvertedAudio {
        var samples: [Int32]
        var frames: Int
        var inexact: Int64
        var ptsNs: Int64
    }

    /// Converts the sample buffer's PCM into interleaved int32 top-aligned 24-bit.
    static func convert(_ sb: CMSampleBuffer, format: AudioFormatInfo) -> ConvertedAudio? {
        let frames = Int(CMSampleBufferGetNumSamples(sb))
        guard frames > 0 else { return nil }
        var sizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil,
                                                                             bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                             flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr,
                                                                         bufferListSize: sizeNeeded, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                         flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        var ptrs: [UnsafeRawPointer?] = []
        for b in abl { ptrs.append(UnsafeRawPointer(b.mData)) }
        if ptrs.isEmpty || ptrs.contains(where: { $0 == nil }) { return nil }
        if format.nonInterleaved && ptrs.count < format.channels { return nil }
        var out = [Int32](repeating: 0, count: frames * format.channels)
        let inexact = ptrs.withUnsafeBufferPointer { pp -> Int64 in
            out.withUnsafeMutableBufferPointer { op -> Int64 in
                lc_audio_convert_to_s32_24(pp.baseAddress, format.nonInterleaved ? 1 : 0, format.source, Int32(format.channels), Int32(frames), op.baseAddress)
            }
        }
        _ = blockBuffer
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let ptsNs = Int64(CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value)
        return ConvertedAudio(samples: out, frames: frames, inexact: inexact, ptsNs: ptsNs)
    }

    // MARK: Writers

    private func documentsPath(_ name: String) -> String {
        Recording.documentsDirectory().appendingPathComponent(name).path
    }

    /// Opens hash list + intermediate / MKV writers. Called with `lock` held.
    private func openWritersLocked(firstVideoPts: Int64) {
        guard let cfg = config else { return }
        var err = [CChar](repeating: 0, count: 256)
        let af = audioFormat
        let hdr = LCHashListHeader(width: Int32(cfg.width), height: Int32(cfg.height), bit_depth: Int32(cfg.bitDepth),
                                   full_range: cfg.fullRange ? 1 : 0, fps_num: Int32(cfg.fps), fps_den: 1,
                                   audio_sample_rate: Int32(af?.sampleRate ?? 0), audio_channels: Int32(af?.channels ?? 0),
                                   audio_checkpoint_interval: Int32(af?.sampleRate ?? 48000))
        nextAudioCheckpoint = Int64(af?.sampleRate ?? 48000)
        audioEnabledForTake = af != nil
        if af == nil && cfg.audioExpected { notes.append("No audio buffers arrived within 0.4 s of the first frame; the take has no audio stream") }
        hashList = lc_hashlist_open(documentsPath(cfg.baseName + ".lchash"), [hdr], &err, 256)
        if hashList == nil { notes.append("Hash list: \(String(cString: err))") }

        let ambisonic = (af?.channels == 4 && cfg.settings.audio == .spatial) ? 1 : 0
        if cfg.captureMode == .twoStage {
            var c = LCIntermediateConfig()
            c.width = Int32(cfg.width); c.height = Int32(cfg.height)
            c.bytes_per_sample = Int32(cfg.bytesPerSample); c.bit_depth = Int32(cfg.bitDepth)
            c.full_range = cfg.fullRange ? 1 : 0
            c.color_primaries = cfg.colour.primaries; c.color_trc = cfg.colour.transfer
            c.colorspace = cfg.colour.matrix; c.chroma_location = cfg.colour.chromaLocation
            c.fps_num = Int32(cfg.fps); c.fps_den = 1
            c.codec = cfg.stage1Codec.lcCodec
            c.audio_sample_rate = Int32(af?.sampleRate ?? 0); c.audio_channels = Int32(af?.channels ?? 0)
            c.audio_ambisonic = Int32(ambisonic)
            // Extradata (FFV1 fast) comes from a probe encoder so every worker shares it.
            s1Extradata = []
            if cfg.stage1Codec == .ffv1Fast || cfg.stage1Codec == .utvideo {
                if let probe = lc_s1_encoder_create(&c, &err, 256) {
                    var n: Int = 0
                    if let x = lc_s1_encoder_extradata(probe, &n), n > 0 {
                        s1Extradata = Array(UnsafeBufferPointer(start: x, count: n))
                    }
                    lc_s1_encoder_destroy(probe)
                }
            }
            lci = s1Extradata.withUnsafeBufferPointer { xp in
                lc_lci_open(documentsPath(cfg.baseName + ".lci"), &c, xp.baseAddress, s1Extradata.count, &err, 256)
            }
            if lci == nil {
                failLocked("Intermediate file could not be created: \(String(cString: err))")
            } else {
                for chunk in pendingAudio {
                    chunk.samples.withUnsafeBufferPointer { p in
                        _ = lc_lci_append_audio(lci, chunk.pts, p.baseAddress, Int32(chunk.samples.count / max(af?.channels ?? 1, 1)))
                    }
                }
                pendingAudio.removeAll()
            }
        } else {
            var m = LCMkvConfig()
            m.width = Int32(cfg.width); m.height = Int32(cfg.height)
            m.pix_fmt = cfg.bytesPerSample == 2 ? LC_PIX_YUV420P10 : LC_PIX_YUV420P8
            m.full_range = cfg.fullRange ? 1 : 0
            m.color_primaries = cfg.colour.primaries; m.color_trc = cfg.colour.transfer
            m.colorspace = cfg.colour.matrix; m.chroma_location = cfg.colour.chromaLocation
            m.fps_num = Int32(cfg.fps); m.fps_den = 1
            m.ffv1 = cfg.ffv1
            m.audio_enabled = af != nil ? 1 : 0
            m.audio_sample_rate = Int32(af?.sampleRate ?? 0); m.audio_channels = Int32(af?.channels ?? 0)
            m.audio_ambisonic = Int32(ambisonic)
            m.flac_compression_level = Int32(cfg.flacLevel)
            let meta = RecordingPipeline.metadata(for: cfg, audio: af)
            let mkvPath = documentsPath(cfg.baseName + ".mkv")
            mkv = withCStringArray(meta) { arr -> OpaquePointer? in
                m.metadata = arr
                return lc_mkv_open(mkvPath, &m, &err, 256)
            }
            if mkv == nil {
                failLocked("MKV writer could not be created: \(String(cString: err))")
            } else {
                lc_mkv_set_origin(mkv, firstVideoPts)
                audioQueue.insert(contentsOf: pendingAudio, at: 0)
                pendingAudio.removeAll()
            }
        }
        writersOpen = true
        for _ in 0..<workerCount { writersReady.signal() }
    }

    /// Stops accepting frames and tells the UI why. Called with `lock` held.
    private func failLocked(_ message: String) {
        recording = false
        if failure == nil { failure = message }
        notes.append(message)
        DiagnosticsLog.shared.log("pipeline", message)
        DispatchQueue.main.async { self.fatalFailure = message }
    }

    static func metadata(for cfg: Config, audio: AudioFormatInfo?) -> [String] {
        var m: [String] = [
            "LOSSLESSCAM_APP", "LosslessCam \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")",
            "LOSSLESSCAM_DEVICE", cfg.deviceModel,
            "LOSSLESSCAM_SOURCE_PIXEL_FORMAT", cfg.pixelFormatFourCC,
            "LOSSLESSCAM_COLOUR", cfg.colour.description,
            "LOSSLESSCAM_CAPTURE_MODE", cfg.captureMode.shortName,
            "LOSSLESSCAM_PRESET", cfg.settings.preset.rawValue,
            "LOSSLESSCAM_STABILIZATION", cfg.settings.stabilization.rawValue,
            "LOSSLESSCAM_REFERENCE", cfg.referencePath
        ]
        if cfg.captureMode == .twoStage { m += ["LOSSLESSCAM_STAGE1_CODEC", cfg.stage1Codec.shortName] }
        if let a = audio { m += ["LOSSLESSCAM_AUDIO_SOURCE_FORMAT", a.description] }
        return m
    }

    // MARK: Workers

    private func lockedPlanes(_ pb: CVPixelBuffer) -> (y: UnsafePointer<UInt8>, ys: Int, c: UnsafePointer<UInt8>, cs: Int)? {
        guard CVPixelBufferGetPlaneCount(pb) >= 2,
              let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        return (UnsafePointer(y.assumingMemoryBound(to: UInt8.self)), CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                UnsafePointer(c.assumingMemoryBound(to: UInt8.self)), CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
    }

    private func recordHash(index: Int64, pts: Int64, hash: UInt64) {
        lock.lock()
        reorder[index] = (pts, hash)
        while let e = reorder[nextHashIndex] {
            if let hl = hashList { _ = lc_hashlist_add_video(hl, nextHashIndex, e.pts, e.hash) }
            reorder.removeValue(forKey: nextHashIndex)
            nextHashIndex += 1
        }
        lock.unlock()
    }

    private func stage1WorkerLoop(index: Int) {
        defer { workerGroup.leave() }
        writersReady.wait()
        lock.lock()
        guard let cfg = config, let ring = ring, let lci = lci else { lock.unlock(); return }
        var c = LCIntermediateConfig()
        c.width = Int32(cfg.width); c.height = Int32(cfg.height)
        c.bytes_per_sample = Int32(cfg.bytesPerSample); c.bit_depth = Int32(cfg.bitDepth)
        c.full_range = cfg.fullRange ? 1 : 0
        c.color_primaries = cfg.colour.primaries; c.color_trc = cfg.colour.transfer
        c.colorspace = cfg.colour.matrix; c.chroma_location = cfg.colour.chromaLocation
        c.fps_num = Int32(cfg.fps); c.fps_den = 1
        c.codec = cfg.stage1Codec.lcCodec
        lock.unlock()
        var err = [CChar](repeating: 0, count: 256)
        guard let enc = lc_s1_encoder_create(&c, &err, 256) else {
            lock.lock(); notes.append("Worker \(index): \(String(cString: err))"); lock.unlock()
            return
        }
        defer { lc_s1_encoder_destroy(enc) }
        let rawSize = cfg.frameBytes
        while let slot = ring.pop() {
            let pb = slot.pixelBuffer
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            if let p = lockedPlanes(pb) {
                let hash = lc_hash_biplanar(p.y, p.ys, p.c, p.cs, Int32(cfg.width), Int32(cfg.height), Int32(cfg.bytesPerSample))
                var out: UnsafePointer<UInt8>? = nil
                var n: Int = 0
                let rc = lc_s1_encoder_compress(enc, p.y, p.ys, p.c, p.cs, &out, &n)
                if rc >= 0, let out = out {
                    let ok = lc_lci_append_video(lci, slot.outputIndex, slot.ptsNs, hash, out, n, rawSize) == 0
                    if ok {
                        recordHash(index: slot.outputIndex, pts: slot.ptsNs, hash: hash)
                        lock.lock(); writtenFrames += 1; writeRate.add(1, at: CACurrentMediaTime()); lock.unlock()
                    } else {
                        lock.lock(); failLocked("Intermediate write failed at frame \(slot.outputIndex) (storage full?) — recording stopped"); lock.unlock()
                    }
                } else {
                    lock.lock(); notes.append("Stage-1 compression failed (\(rc)) at frame \(slot.outputIndex)"); lock.unlock()
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            ring.release(slot)
        }
    }

    private func drainAudioQueueLocked(upTo pts: Int64?) {
        guard let mkv = mkv else { audioQueue.removeAll(); return }
        while let first = audioQueue.first, pts == nil || first.pts <= pts! {
            audioQueue.removeFirst()
            let ch = max(audioFormat?.channels ?? 1, 1)
            let interval = Int64(audioFormat?.sampleRate ?? 48000)
            lock.unlock()
            first.samples.withUnsafeBufferPointer { p in
                _ = lc_mkv_write_audio(mkv, p.baseAddress, Int32(first.samples.count / ch), first.pts)
            }
            let committed = lc_mkv_audio_frames_written(mkv)
            let running = lc_mkv_audio_running_hash(mkv)
            lock.lock()
            while committed >= nextAudioCheckpoint {
                if let hl = hashList { _ = lc_hashlist_add_audio_checkpoint(hl, committed, first.pts, running) }
                nextAudioCheckpoint = committed + interval
            }
        }
    }

    private func realtimeEncodeLoop() {
        defer { workerGroup.leave() }
        writersReady.wait()
        lock.lock()
        guard let cfg = config, let ring = ring, let mkv = mkv else { lock.unlock(); return }
        lock.unlock()
        while let slot = ring.pop() {
            lock.lock()
            drainAudioQueueLocked(upTo: slot.ptsNs)
            lock.unlock()
            let pb = slot.pixelBuffer
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            if let p = lockedPlanes(pb) {
                let hash = lc_hash_biplanar(p.y, p.ys, p.c, p.cs, Int32(cfg.width), Int32(cfg.height), Int32(cfg.bytesPerSample))
                let rc = lc_mkv_write_video_biplanar(mkv, p.y, p.ys, p.c, p.cs, slot.ptsNs)
                if rc == 0 {
                    recordHash(index: slot.outputIndex, pts: slot.ptsNs, hash: hash)
                    lock.lock(); writtenFrames += 1; writeRate.add(1, at: CACurrentMediaTime()); lock.unlock()
                } else {
                    lock.lock(); failLocked("FFV1 write failed at frame \(slot.outputIndex): \(String(cString: lc_mkv_last_error(mkv))) — recording stopped"); lock.unlock()
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            ring.release(slot)
        }
        lock.lock()
        drainAudioQueueLocked(upTo: nil)
        lowBits = lc_mkv_low_bits_seen(mkv)
        lock.unlock()
    }

    // MARK: Telemetry

    private func startTelemetryTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: telemetryQueue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.publishTelemetry() }
        t.resume()
        timer = t
    }

    private func publishTelemetry() {
        let now = CACurrentMediaTime()
        lock.lock()
        guard let cfg = config else { lock.unlock(); return }
        var t = Telemetry()
        t.isRecording = recording
        t.elapsedSeconds = firstVideoWall > 0 ? now - firstVideoWall : 0
        t.framesIngested = deliveredFrames
        t.framesWritten = writtenFrames
        t.framesAccepted = acceptedFrames
        t.droppedFrames = droppedFrames
        t.sourceDroppedFrames = sourceDrops
        t.achievedFps = writeRate.rate(at: now)
        t.ingestFps = ingestRate.rate(at: now)
        let recentDrops = dropRate.rate(at: now)
        t.recentDropFraction = t.ingestFps > 0.1 ? min(max(recentDrops / t.ingestFps, 0), 1) : 0
        t.keptFraction = deliveredFrames > 0 ? Double(acceptedFrames) / Double(deliveredFrames) : 1
        if firstAcceptedPts >= 0 && lastAcceptedPts >= firstAcceptedPts {
            t.timelineSeconds = Double(lastAcceptedPts - firstAcceptedPts) / 1e9 + 1.0 / Double(max(cfg.fps, 1))
        }
        t.contentSeconds = Double(acceptedFrames) / Double(max(cfg.fps, 1))
        if let r = ring {
            t.bufferCount = r.count
            t.bufferCapacity = r.capacity
            t.bufferFill = Double(r.count) / Double(max(r.capacity, 1))
            peakFill = max(peakFill, t.bufferFill)
        }
        var bytes: Int64 = 0
        if let l = lci { bytes = Int64(lc_lci_bytes_written(l)) }
        if let m = mkv { bytes = Int64(lc_mkv_bytes_written(m)) }
        bytesRate.add(Double(bytes - lastBytes), at: now)
        lastBytes = bytes
        t.bytesWritten = bytes
        t.rawBytes = writtenFrames * Int64(cfg.frameBytes)
        t.compressionRatio = bytes > 0 ? Double(t.rawBytes) / Double(bytes) : 0
        t.writeMBps = bytesRate.rate(at: now) / 1_048_576
        t.thermalState = ProcessInfo.processInfo.thermalState
        maxThermal = max(maxThermal, t.thermalState.rawValue)
        t.freeStorageBytes = freeStorageBytes()
        t.estimatedRemainingSeconds = t.writeMBps > 0.1 ? Double(t.freeStorageBytes) / (t.writeMBps * 1_048_576) : 0
        t.memoryWarnings = memoryWarnings
        t.availableMemoryBytes = availableMemoryBytes()
        t.audioBuffers = audioBuffers
        t.audioFrames = audioFrames
        t.audioFormat = audioFormat?.description ?? (writersOpen ? "no audio" : "waiting…")
        t.audioInexactSamples = audioInexact
        t.workerCount = workerCount
        t.stage1Codec = cfg.captureMode == .twoStage ? cfg.stage1Codec.label : "FFV1 real-time"
        t.notes = notes
        t.failure = failure
        if recording && t.elapsedSeconds > 1 { fpsSamples.append(t.achievedFps); mbpsSamples.append(t.writeMBps) }
        lock.unlock()
        DispatchQueue.main.async { self.telemetry = t }
    }

    private func handleMemoryWarning() {
        lock.lock()
        memoryWarnings += 1
        if let r = ring, r.capacity > 8 {
            // Shed a quarter of the buffer; frames already queued are kept and drained.
            let newCap = max(8, Int(Double(r.capacity) * 0.75))
            r.setCapacity(newCap)
            notes.append("Memory warning \(memoryWarnings): ring buffer capacity reduced to \(newCap) frames")
        }
        lock.unlock()
        DiagnosticsLog.shared.log("pipeline", "Memory warning during recording")
    }

    // MARK: Stop

    func clearMessage() { lastMessage = nil }

    /// Stops accepting frames immediately (the user pressed stop). The reference
    /// recorder is stopped by the caller at the same moment, so both files end together.
    func endIngest() {
        lock.lock()
        guard config != nil else { lock.unlock(); return }
        recording = false
        let ringRef = ring
        if !writersOpen {
            // Nothing was ever delivered; open anyway so the workers can exit cleanly.
            openWritersLocked(firstVideoPts: firstVideoPts)
        }
        lock.unlock()
        ringRef?.close()
    }

    /// Convenience for callers that stop ingest and finish in one step.
    func stop(referenceURL: URL?, referenceError: String?, completion: @escaping (Recording?) -> Void) {
        endIngest()
        finish(referenceURL: referenceURL, referenceError: referenceError, completion: completion)
    }

    /// Drains the ring buffer, closes the writers and produces the sidecar. Call after `endIngest()`.
    func finish(referenceURL: URL?, referenceError: String?, completion: @escaping (Recording?) -> Void) {
        lock.lock()
        guard let cfg = config else { lock.unlock(); completion(nil); return }
        if recording { lock.unlock(); endIngest(); lock.lock() }
        lock.unlock()

        workerGroup.notify(queue: DispatchQueue.global(qos: .userInitiated)) { [self] in
            self.timer?.cancel(); self.timer = nil
            self.publishTelemetry()
            // Detach the intermediate writer under the lock (no new appends can start), then let
            // the audio appends already in flight land before it is closed.
            self.lock.lock()
            let lciToClose = self.lci
            self.lci = nil
            self.lock.unlock()
            self.appendGroup.wait()
            self.lock.lock()
            self.ring?.releaseResources()
            self.ring = nil
            // Flush any hashes still waiting in the reorder buffer (should be none).
            for k in self.reorder.keys.sorted() {
                if let hl = self.hashList, let e = self.reorder[k] { _ = lc_hashlist_add_video(hl, k, e.pts, e.hash) }
            }
            self.reorder.removeAll()

            var audioInfo: Recording.AudioInfo? = nil
            var mkvName: String? = nil
            var lciName: String? = nil
            var stage2 = Recording.Stage2State()
            var finalAudioFrames: Int64 = 0
            var finalAudioHash: UInt64 = 0
            if let m = self.mkv {
                finalAudioFrames = lc_mkv_audio_frames_written(m)
                finalAudioHash = lc_mkv_audio_running_hash(m)
                let trimmed = lc_mkv_audio_trimmed_frames(m)
                let disc = Int(lc_mkv_audio_discontinuities(m))
                let silence = lc_mkv_audio_silence_frames_inserted(m)
                self.lowBits = lc_mkv_low_bits_seen(m)
                let rc = lc_mkv_close(m)
                self.mkv = nil
                if rc < 0 { self.notes.append("MKV finalisation returned \(rc)") }
                mkvName = cfg.baseName + ".mkv"
                if let af = self.audioFormat, self.audioEnabledForTake {
                    audioInfo = Recording.AudioInfo(sampleRate: af.sampleRate, channels: af.channels,
                                                    ambisonic: af.channels == 4 && cfg.settings.audio == .spatial,
                                                    sourceFormat: af.description, inexactSamples: self.audioInexact,
                                                    trimmedFrames: trimmed, discontinuities: disc, silenceFramesInserted: silence)
                }
            }
            if let l = lciToClose {
                let rc = lc_lci_close(l)
                if rc < 0 { self.notes.append("Intermediate finalisation returned \(rc)") }
                lciName = cfg.baseName + ".lci"
                stage2.status = .pending
                if let af = self.audioFormat, self.audioEnabledForTake {
                    audioInfo = Recording.AudioInfo(sampleRate: af.sampleRate, channels: af.channels,
                                                    ambisonic: af.channels == 4 && cfg.settings.audio == .spatial,
                                                    sourceFormat: af.description, inexactSamples: self.audioInexact,
                                                    trimmedFrames: 0, discontinuities: 0, silenceFramesInserted: 0)
                }
            }
            if let hl = self.hashList {
                _ = lc_hashlist_close(hl, self.writtenFrames, self.droppedFrames, finalAudioFrames, finalAudioHash)
                self.hashList = nil
            }
            let written = self.writtenFrames
            let dropped = self.droppedFrames
            let delivered = self.deliveredFrames
            let srcDrops = self.sourceDrops
            let fps = Double(max(cfg.fps, 1))
            let contentSeconds = Double(written) / fps
            let timelineSeconds: Double = (written > 0 && self.firstAcceptedPts >= 0 && self.lastAcceptedPts >= self.firstAcceptedPts)
                ? Double(self.lastAcceptedPts - self.firstAcceptedPts) / 1e9 + 1.0 / fps
                : contentSeconds
            var telemetrySummary = Recording.TelemetrySummary()
            telemetrySummary.averageFps = self.fpsSamples.isEmpty ? 0 : self.fpsSamples.reduce(0, +) / Double(self.fpsSamples.count)
            telemetrySummary.averageWriteMBps = self.mbpsSamples.isEmpty ? 0 : self.mbpsSamples.reduce(0, +) / Double(self.mbpsSamples.count)
            telemetrySummary.peakBufferFill = self.peakFill
            telemetrySummary.maxThermalState = self.maxThermal
            telemetrySummary.memoryWarnings = self.memoryWarnings
            var notes = self.notes
            if let e = referenceError { notes.append("Reference: \(e)") }
            if dropped > 0 {
                let kept = delivered > 0 ? Double(written) / Double(delivered) * 100 : 0
                notes.append(String(format: "Kept %lld of %lld delivered frames (%.0f%%): %lld frames were dropped because the storage pipeline sustained only %.1f fps (%.0f MB/s). The lossless file keeps the real %.1f s timeline with gaps where frames are missing; the HEVC reference is continuous. To keep every frame, lower resolution/frame rate, run the stage-1 benchmark or free storage bandwidth.",
                                    written, delivered, kept, dropped, telemetrySummary.averageFps, telemetrySummary.averageWriteMBps, timelineSeconds))
            }
            if srcDrops > 0 { notes.append("\(srcDrops) frames were dropped by AVFoundation before delivery") }
            let lowBits = self.lowBits
            let failure = self.failure
            let firstPts = self.firstAcceptedPts
            let lastPts = self.lastAcceptedPts
            self.lock.unlock()

            var rec = Recording(
                baseName: cfg.baseName, createdAt: Date(), width: cfg.width, height: cfg.height, bitDepth: cfg.bitDepth,
                fullRange: cfg.fullRange, fps: cfg.fps, hdr: cfg.colour.isHDR, colorDescription: cfg.colour.description,
                pixelFormatFourCC: cfg.pixelFormatFourCC, captureMode: cfg.captureMode.shortName,
                stage1Codec: cfg.captureMode == .twoStage ? cfg.stage1Codec.shortName : nil,
                preset: cfg.settings.preset.rawValue, stabilization: cfg.settings.stabilization.rawValue,
                frameCount: written, droppedFrames: dropped, sourceDroppedFrames: srcDrops, durationSeconds: timelineSeconds,
                audio: audioInfo,
                files: Recording.Files(mkv: mkvName, hevcReference: referenceURL?.lastPathComponent, hashList: cfg.baseName + ".lchash", intermediate: lciName, thumbnail: nil),
                stage2: stage2, verification: Recording.VerificationState(), referencePath: cfg.referencePath,
                telemetry: telemetrySummary, lowBitsNonZero: lowBits != 0, deviceModel: cfg.deviceModel,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                notes: notes.isEmpty ? nil : notes.joined(separator: "\n"))
            rec.contentSeconds = contentSeconds
            rec.deliveredFrames = delivered
            rec.firstPtsNs = firstPts >= 0 ? firstPts : nil
            rec.lastPtsNs = lastPts >= 0 ? lastPts : nil
            rec.pipelineFailure = failure
            if written == 0 {
                // Nothing recorded: clean up files and report.
                for n in [mkvName, lciName, cfg.baseName + ".lchash"].compactMap({ $0 }) {
                    try? FileManager.default.removeItem(atPath: self.documentsPath(n))
                }
                DispatchQueue.main.async { self.lastMessage = failure ?? "No frames were recorded" }
                completion(nil)
                return
            }
            try? rec.save()
            let summary: String
            if dropped > 0 {
                summary = String(format: "Recorded %lld of %lld frames (%.0f%%) over %.1f s — %lld dropped, pipeline sustained %.1f fps", written, delivered, delivered > 0 ? Double(written) / Double(delivered) * 100 : 0, timelineSeconds, dropped, telemetrySummary.averageFps)
            } else {
                summary = String(format: "Recorded %lld frames (%.1f s), nothing dropped", written, timelineSeconds)
            }
            DispatchQueue.main.async {
                self.lastMessage = failure.map { "\($0). \(summary)" } ?? summary
                var t = self.telemetry; t.isRecording = false; self.telemetry = t
            }
            if cfg.captureMode == .twoStage {
                Stage2Runner.shared.enqueue(recording: rec, ffv1: cfg.ffv1, flacLevel: cfg.flacLevel, metadata: RecordingPipeline.metadata(for: cfg, audio: self.audioFormat))
            } else {
                Stage2Runner.shared.enqueueVerification(recording: rec)
            }
            rec.fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: self.documentsPath(mkvName ?? lciName ?? ""))[.size] as? NSNumber)?.int64Value ?? 0
            completion(rec)
        }
    }
}

/// Calls `body` with a NULL-terminated `const char *const *` built from `strings`.
func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    var cstrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    cstrs.append(nil)
    defer { for p in cstrs { free(p) } }
    return cstrs.withUnsafeBufferPointer { buf in
        buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: cstrs.count) { body($0) }
    }
}
