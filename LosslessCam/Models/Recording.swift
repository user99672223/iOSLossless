import Foundation

/// Sidecar metadata stored next to each recording as `<base>.json`.
///
/// Timeline vocabulary used throughout the app:
/// - `durationSeconds` is the real timeline the file spans (first kept frame →
///   last kept frame, by AVFoundation presentation timestamps);
/// - `contentSeconds` is `frameCount / fps`, i.e. how much footage exists;
/// - the two differ exactly when frames were dropped (gaps in the timeline).
struct Recording: Codable, Identifiable, Equatable {
    struct AudioInfo: Codable, Equatable {
        var sampleRate: Int
        var channels: Int
        var ambisonic: Bool
        var sourceFormat: String
        var inexactSamples: Int64
        var trimmedFrames: Int64
        var discontinuities: Int
        var silenceFramesInserted: Int64
    }

    struct Files: Codable, Equatable {
        var mkv: String?
        var hevcReference: String?
        var hashList: String
        var intermediate: String?
        var thumbnail: String?
    }

    enum Stage2Status: String, Codable { case notNeeded, pending, running, done, failed, cancelled }
    struct Stage2State: Codable, Equatable {
        var status: Stage2Status = .notNeeded
        var progress: Double = 0
        var error: String?
        var seconds: Double = 0
        var intermediateHashMismatches: Int64 = 0
        var recoveredWithoutTrailer: Bool = false
        /// Recovered intermediate: frames at an undecodable tail that could not be rebuilt.
        var framesUnreadable: Int64?
    }

    enum VerificationStatus: String, Codable { case notRun, running, pass, fail, error, cancelled }
    struct VerificationState: Codable, Equatable {
        var status: VerificationStatus = .notRun
        var videoStatus: VerificationStatus = .notRun
        var audioStatus: VerificationStatus = .notRun
        var framesChecked: Int64 = 0
        var framesExpected: Int64 = 0
        var firstMismatchFrame: Int64 = -1
        var audioFramesChecked: Int64 = 0
        var audioFirstMismatchFrame: Int64 = -1
        var crcErrors: Int = 0
        var sliceCrcChecked: Bool = false
        var checkedAt: Date?
        var seconds: Double = 0
        var message: String?
        /// Interrupted recording: stored frames that have no capture hash (not verifiable).
        var framesUnverified: Int64?
    }

    struct TelemetrySummary: Codable, Equatable {
        var averageFps: Double = 0
        var peakBufferFill: Double = 0
        var averageWriteMBps: Double = 0
        var maxThermalState: Int = 0
        var memoryWarnings: Int = 0
    }

    var id: String { baseName }
    var baseName: String
    var createdAt: Date
    var width: Int
    var height: Int
    var bitDepth: Int
    var fullRange: Bool
    var fps: Int
    var hdr: Bool
    var colorDescription: String
    var pixelFormatFourCC: String
    var captureMode: String
    var stage1Codec: String?
    var preset: String
    var stabilization: String
    var frameCount: Int64
    var droppedFrames: Int64
    var sourceDroppedFrames: Int64
    /// Real timeline spanned by the kept frames (seconds).
    var durationSeconds: Double
    var audio: AudioInfo?
    var files: Files
    var stage2: Stage2State
    var verification: VerificationState
    var referencePath: String
    var telemetry: TelemetrySummary
    var lowBitsNonZero: Bool
    var deviceModel: String
    var appVersion: String
    var notes: String?

    // Timeline details (optional: sidecars written by older builds lack them).
    var contentSeconds: Double?
    var deliveredFrames: Int64?
    var firstPtsNs: Int64?
    var lastPtsNs: Int64?
    var pipelineFailure: String?

    // Not persisted, filled at scan time.
    var fileSizeBytes: Int64 = 0
    var referenceSizeBytes: Int64 = 0

    private enum CodingKeys: String, CodingKey {
        case baseName, createdAt, width, height, bitDepth, fullRange, fps, hdr, colorDescription, pixelFormatFourCC
        case captureMode, stage1Codec, preset, stabilization, frameCount, droppedFrames, sourceDroppedFrames
        case durationSeconds, audio, files, stage2, verification, referencePath, telemetry, lowBitsNonZero
        case deviceModel, appVersion, notes
        case contentSeconds, deliveredFrames, firstPtsNs, lastPtsNs, pipelineFailure
    }

    var resolutionLabel: String { height >= 2160 ? "4K" : (height >= 1080 ? "1080p" : "\(width)×\(height)") }
    var hasReference: Bool { files.hevcReference != nil }
    var isReady: Bool { files.mkv != nil && (stage2.status == .done || stage2.status == .notNeeded) }

    /// Footage length (frames / fps); falls back to the timeline when unknown.
    var contentDuration: Double { contentSeconds ?? (fps > 0 ? Double(frameCount) / Double(fps) : durationSeconds) }
    /// Share of delivered frames that were kept, when the sidecar knows how many were delivered.
    var keptFraction: Double? {
        guard let d = deliveredFrames, d > 0 else { return nil }
        return Double(frameCount) / Double(d)
    }
    var hasGaps: Bool { droppedFrames > 0 && durationSeconds > contentDuration + 0.01 }

    /// One-line timeline description for lists: "21.0 s · 240 fr (4.0 s of footage, 19% kept)".
    var timelineLabel: String {
        if hasGaps {
            let kept = keptFraction.map { String(format: ", %.0f%% kept", $0 * 100) } ?? ""
            return String(format: "%.1f s timeline · %lld fr (%.1f s footage%@)", durationSeconds, frameCount, contentDuration, kept)
        }
        return String(format: "%.1f s · %lld fr", durationSeconds, frameCount)
    }

    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func url(for name: String?) -> URL? {
        guard let name = name else { return nil }
        return Recording.documentsDirectory().appendingPathComponent(name)
    }
    var mkvURL: URL? { url(for: files.mkv) }
    var referenceURL: URL? { url(for: files.hevcReference) }
    var hashListURL: URL { Recording.documentsDirectory().appendingPathComponent(files.hashList) }
    var intermediateURL: URL? { url(for: files.intermediate) }
    var sidecarURL: URL { Recording.documentsDirectory().appendingPathComponent(baseName + ".json") }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(self)
        try data.write(to: sidecarURL, options: .atomic)
    }

    static func load(from url: URL) throws -> Recording {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var r = try dec.decode(Recording.self, from: Data(contentsOf: url))
        if let mkv = r.mkvURL, let attrs = try? FileManager.default.attributesOfItem(atPath: mkv.path),
           let size = attrs[.size] as? NSNumber {
            r.fileSizeBytes = size.int64Value
        }
        if r.files.mkv == nil, let lci = r.intermediateURL, let attrs = try? FileManager.default.attributesOfItem(atPath: lci.path),
           let size = attrs[.size] as? NSNumber {
            r.fileSizeBytes = size.int64Value   // pending two-stage recording: the intermediate holds the footage
        }
        if let ref = r.referenceURL, let attrs = try? FileManager.default.attributesOfItem(atPath: ref.path),
           let size = attrs[.size] as? NSNumber {
            r.referenceSizeBytes = size.int64Value
        }
        return r
    }
}

extension Int64 {
    var byteCountString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Double {
    var durationString: String {
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
