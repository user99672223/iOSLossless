import Foundation
import UIKit
import Combine

/// Lists recordings in the app's Documents directory (visible in the Files app
/// and over USB thanks to UIFileSharingEnabled) and produces thumbnails.
final class LibraryStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var scanning = false

    private var observer: NSObjectProtocol?
    private let thumbQueue = DispatchQueue(label: "com.losslesscam.thumbs", qos: .utility)
    private var thumbCache: [String: UIImage] = [:]
    private let cacheLock = NSLock()

    init() {
        observer = NotificationCenter.default.addObserver(forName: Stage2Runner.recordingUpdated, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    func refresh() {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let dir = Recording.documentsDirectory()
            var found: [Recording] = []
            var seen = Set<String>()
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            for url in items where url.pathExtension == "json" {
                if let r = try? Recording.load(from: url) {
                    found.append(r)
                    seen.insert(r.baseName)
                }
            }
            // A file still being written (the recording in progress) has no sidecar yet: leave it alone.
            func isSettled(_ url: URL) -> Bool {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return Date().timeIntervalSince(m) > 10
            }
            // Intermediates without a sidecar: the app stopped (crash, jetsam) during a two-stage
            // recording. Adopt them so stage 2 can build the MKV from what reached the flash.
            for url in items where url.pathExtension == "lci" {
                let base = url.deletingPathExtension().lastPathComponent
                if seen.contains(base) || !isSettled(url) { continue }
                if let r = Self.adoptIntermediate(url: url) { found.append(r); seen.insert(base) }
            }
            // Orphan MKVs (imported through Files, an interrupted real-time recording, or a lost sidecar).
            for url in items where url.pathExtension == "mkv" {
                let base = url.deletingPathExtension().lastPathComponent
                if seen.contains(base) || !isSettled(url) { continue }
                if let r = Self.probe(url: url) {
                    try? r.save()   // probing can scan a whole unfinalised file; do it once
                    found.append(r); seen.insert(base)
                }
            }
            found.sort { $0.createdAt > $1.createdAt }
            DispatchQueue.main.async {
                self.recordings = found
                self.scanning = false
            }
        }
    }

    /// Builds the sidecar for an intermediate left behind by an interrupted two-stage recording.
    static func adoptIntermediate(url: URL) -> Recording? {
        var err = [CChar](repeating: 0, count: 256)
        var cfg = LCIntermediateConfig()
        var pr = LCIntermediateProbe()
        guard lc_lci_probe(url.path, &cfg, &pr, &err, 256) == 0, pr.video_frames > 0 else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = (attrs?[.creationDate] as? Date) ?? Date()
        let fps = cfg.fps_den > 0 ? Int((Double(cfg.fps_num) / Double(cfg.fps_den)).rounded()) : 60
        let timeline = Double(pr.last_video_pts_ns - pr.first_video_pts_ns) / 1e9 + 1.0 / Double(max(fps, 1))
        let refName = base + "_HEVC.mov"
        let hasRef = FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(refName).path)
        let audio: Recording.AudioInfo? = cfg.audio_sample_rate > 0 && cfg.audio_channels > 0
            ? Recording.AudioInfo(sampleRate: Int(cfg.audio_sample_rate), channels: Int(cfg.audio_channels), ambisonic: cfg.audio_ambisonic != 0,
                                  sourceFormat: "recovered", inexactSamples: 0, trimmedFrames: 0, discontinuities: 0, silenceFramesInserted: 0)
            : nil
        let hdr = cfg.color_trc == Int32(LC_COLOR_TRC_ARIB_STD_B67)
        var r = Recording(baseName: base, createdAt: created, width: Int(cfg.width), height: Int(cfg.height), bitDepth: Int(cfg.bit_depth),
                          fullRange: cfg.full_range != 0, fps: fps, hdr: hdr,
                          colorDescription: hdr ? "BT.2020 / HLG (ARIB STD-B67) / BT.2020 NCL" : "BT.709 / BT.709 / BT.709",
                          pixelFormatFourCC: cfg.bit_depth == 10 ? "x420" : "420v", captureMode: "twoStage",
                          stage1Codec: String(cString: lc_stage1_codec_name(cfg.codec)),
                          preset: "—", stabilization: "—", frameCount: pr.video_frames, droppedFrames: 0, sourceDroppedFrames: 0,
                          durationSeconds: max(timeline, 0), audio: audio,
                          files: Recording.Files(mkv: nil, hevcReference: hasRef ? refName : nil, hashList: base + ".lchash", intermediate: url.lastPathComponent, thumbnail: nil),
                          stage2: Recording.Stage2State(status: .pending), verification: Recording.VerificationState(),
                          referencePath: hasRef ? "recovered" : "none", telemetry: Recording.TelemetrySummary(), lowBitsNonZero: false,
                          deviceModel: CaptureManager.deviceModelIdentifier(), appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                          notes: "Recovered after the app stopped during recording: \(pr.video_frames) frames reached the intermediate" + (pr.recovered_without_trailer != 0 ? " (chunk table rebuilt by scanning)" : "") + ". Dropped-frame counts from the live session are unknown.")
        r.contentSeconds = Double(pr.video_frames) / Double(max(fps, 1))
        r.firstPtsNs = pr.first_video_pts_ns
        r.lastPtsNs = pr.last_video_pts_ns
        r.pipelineFailure = "Recording was interrupted (app stopped); recovered from the intermediate"
        try? r.save()
        DiagnosticsLog.shared.log("library", "Adopted interrupted recording \(base): \(pr.video_frames) frames")
        return (try? Recording.load(from: r.sidecarURL)) ?? r
    }

    /// Builds minimal metadata for an MKV without a sidecar by probing it.
    static func probe(url: URL) -> Recording? {
        var err = [CChar](repeating: 0, count: 256)
        guard let dec = lc_decoder_open(url.path, 1, 1, 1, &err, 256) else { return nil }
        var info = LCMediaInfo()
        lc_decoder_get_info(dec, &info)
        lc_decoder_close(dec)
        guard info.has_video != 0 else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = (attrs?[.creationDate] as? Date) ?? Date()
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let fps = info.fps_den > 0 ? Int((Double(info.fps_num) / Double(info.fps_den)).rounded()) : 0
        let hasHash = FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("lchash").path)
        let refName = base + "_HEVC.mov"
        let hasRef = FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(refName).path)
        let audioCodec = withUnsafePointer(to: &info.audio_codec) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        let audioInfo: Recording.AudioInfo? = info.has_audio != 0
            ? Recording.AudioInfo(sampleRate: Int(info.sample_rate), channels: Int(info.channels), ambisonic: info.audio_ambisonic != 0,
                                  sourceFormat: audioCodec, inexactSamples: 0, trimmedFrames: 0, discontinuities: 0, silenceFramesInserted: 0)
            : nil
        var r = Recording(baseName: base, createdAt: created, width: Int(info.width), height: Int(info.height), bitDepth: Int(info.bit_depth),
                          fullRange: info.full_range != 0, fps: fps, hdr: info.color_trc == Int32(LC_COLOR_TRC_ARIB_STD_B67),
                          colorDescription: "primaries \(info.color_primaries) / trc \(info.color_trc) / matrix \(info.colorspace)",
                          pixelFormatFourCC: info.bit_depth == 10 ? "x420" : "420v", captureMode: "imported", stage1Codec: nil,
                          preset: "—", stabilization: "—", frameCount: info.frame_count, droppedFrames: 0, sourceDroppedFrames: 0,
                          durationSeconds: Double(info.duration_ns) / 1e9,
                          audio: audioInfo,
                          files: Recording.Files(mkv: url.lastPathComponent, hevcReference: hasRef ? refName : nil, hashList: base + ".lchash", intermediate: nil, thumbnail: nil),
                          stage2: Recording.Stage2State(status: .notNeeded), verification: Recording.VerificationState(status: hasHash ? .notRun : .error, message: hasHash ? nil : "No hash list for this file"),
                          referencePath: "unknown", telemetry: Recording.TelemetrySummary(), lowBitsNonZero: false,
                          deviceModel: "unknown", appVersion: "imported", notes: "Metadata reconstructed by probing the file")
        r.fileSizeBytes = size
        r.contentSeconds = fps > 0 ? Double(info.frame_count) / Double(fps) : nil
        if info.finalized == 0 {
            r.notes = "Metadata reconstructed by probing the file. The file was not finalised (the app stopped while writing it); its frame index was rebuilt by scanning."
            r.pipelineFailure = "Recording was interrupted (app stopped); the file was not finalised"
        }
        return r
    }

    func delete(_ recording: Recording) {
        let dir = Recording.documentsDirectory()
        let b = recording.baseName
        // By base name as well as by the sidecar's list, so no leftover (e.g. a partial MKV) reappears as an orphan.
        var names: [String] = [b + ".json", b + ".lchash", b + ".mkv", b + ".mkv.part", b + ".lci", b + "_HEVC.mov", recording.files.hashList]
        if let m = recording.files.mkv { names.append(m) }
        if let r = recording.files.hevcReference { names.append(r) }
        if let i = recording.files.intermediate { names.append(i) }
        for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
        try? FileManager.default.removeItem(at: thumbnailURL(for: recording))
        cacheLock.lock(); thumbCache.removeValue(forKey: recording.baseName); cacheLock.unlock()
        refresh()
    }

    func deleteReference(_ recording: Recording) {
        guard let ref = recording.referenceURL else { return }
        try? FileManager.default.removeItem(at: ref)
        var r = recording
        r.files.hevcReference = nil
        try? r.save()
        refresh()
    }

    // MARK: Thumbnails

    private func thumbnailURL(for r: Recording) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(r.baseName + "_thumb.png")
    }

    func thumbnail(for r: Recording, completion: @escaping (UIImage?) -> Void) {
        cacheLock.lock()
        if let img = thumbCache[r.baseName] { cacheLock.unlock(); completion(img); return }
        cacheLock.unlock()
        let url = thumbnailURL(for: r)
        thumbQueue.async { [self] in
            var image: UIImage? = nil
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                image = img
            } else if let mkv = r.mkvURL, let img = Self.renderThumbnail(path: mkv.path, colorspace: Int32(LC_COLOR_SPC_BT2020_NCL)) {
                image = img
                if let data = img.pngData() { try? data.write(to: url) }
            }
            if let img = image { cacheLock.lock(); thumbCache[r.baseName] = img; cacheLock.unlock() }
            DispatchQueue.main.async { completion(image) }
        }
    }

    static func renderThumbnail(path: String, colorspace: Int32, width: Int = 320) -> UIImage? {
        var err = [CChar](repeating: 0, count: 256)
        guard let dec = lc_decoder_open(path, 1, 0, 2, &err, 256) else { return nil }
        defer { lc_decoder_close(dec) }
        var info = LCMediaInfo()
        lc_decoder_get_info(dec, &info)
        // A frame a little into the clip is more representative than frame 0.
        let target = min(max(info.frame_count / 10, 0), max(info.frame_count - 1, 0))
        if target > 0 { _ = lc_decoder_seek_frame(dec, target) }
        var frame = LCVideoFrame()
        guard lc_decoder_next_video(dec, &frame) == 1 else { return nil }
        let h = max(Int(Double(width) * Double(frame.height) / Double(max(frame.width, 1))), 1)
        var rgba = [UInt8](repeating: 0, count: width * h * 4)
        let ok = rgba.withUnsafeMutableBufferPointer { p in
            lc_frame_to_rgba8(&frame, info.full_range, info.colorspace != 0 ? info.colorspace : colorspace, p.baseAddress, Int32(width), Int32(h), width * 4)
        }
        guard ok == 0 else { return nil }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: width, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Total size of everything in Documents.
    var totalBytes: Int64 {
        recordings.reduce(0) { $0 + $1.fileSizeBytes + $1.referenceSizeBytes }
    }
}
