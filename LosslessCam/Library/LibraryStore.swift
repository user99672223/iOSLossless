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
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            for url in items where url.pathExtension == "json" {
                if let r = try? Recording.load(from: url) {
                    found.append(r)
                    seen.insert(r.baseName)
                }
            }
            // Orphan MKVs (imported through Files, or whose sidecar was lost).
            for url in items where url.pathExtension == "mkv" {
                let base = url.deletingPathExtension().lastPathComponent
                if seen.contains(base) { continue }
                if let r = Self.probe(url: url) { found.append(r); seen.insert(base) }
            }
            found.sort { $0.createdAt > $1.createdAt }
            DispatchQueue.main.async {
                self.recordings = found
                self.scanning = false
            }
        }
    }

    /// Builds minimal metadata for an MKV without a sidecar by probing it.
    static func probe(url: URL) -> Recording? {
        var err = [CChar](repeating: 0, count: 256)
        guard let dec = lc_decoder_open(url.path, 1, 1, 1, &err, err.count) else { return nil }
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
        var r = Recording(baseName: base, createdAt: created, width: Int(info.width), height: Int(info.height), bitDepth: Int(info.bit_depth),
                          fullRange: info.full_range != 0, fps: fps, hdr: info.color_trc == Int32(LC_COLOR_TRC_ARIB_STD_B67),
                          colorDescription: "primaries \(info.color_primaries) / trc \(info.color_trc) / matrix \(info.colorspace)",
                          pixelFormatFourCC: info.bit_depth == 10 ? "x420" : "420v", captureMode: "imported", stage1Codec: nil,
                          preset: "—", stabilization: "—", frameCount: info.frame_count, droppedFrames: 0, sourceDroppedFrames: 0,
                          durationSeconds: Double(info.duration_ns) / 1e9,
                          audio: info.has_audio != 0 ? Recording.AudioInfo(sampleRate: Int(info.sample_rate), channels: Int(info.channels), ambisonic: info.audio_ambisonic != 0,
                                                                            sourceFormat: String(cString: withUnsafePointer(to: &info.audio_codec) { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }),
                                                                            inexactSamples: 0, trimmedFrames: 0, discontinuities: 0, silenceFramesInserted: 0) : nil,
                          files: Recording.Files(mkv: url.lastPathComponent, hevcReference: hasRef ? refName : nil, hashList: base + ".lchash", intermediate: nil, thumbnail: nil),
                          stage2: Recording.Stage2State(status: .notNeeded), verification: Recording.VerificationState(status: hasHash ? .notRun : .error, message: hasHash ? nil : "No hash list for this file"),
                          referencePath: "unknown", telemetry: Recording.TelemetrySummary(), lowBitsNonZero: false,
                          deviceModel: "unknown", appVersion: "imported", notes: "Metadata reconstructed by probing the file")
        r.fileSizeBytes = size
        return r
    }

    func delete(_ recording: Recording) {
        let dir = Recording.documentsDirectory()
        var names: [String] = [recording.baseName + ".json", recording.files.hashList]
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
        guard let dec = lc_decoder_open(path, 1, 0, 2, &err, err.count) else { return nil }
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
