import Foundation
import AVFoundation

// MARK: - Enumerations

enum Resolution: String, CaseIterable, Codable, Identifiable {
    case p1080 = "1080p"
    case p2160 = "4K"
    var id: String { rawValue }
    var width: Int32 { self == .p1080 ? 1920 : 3840 }
    var height: Int32 { self == .p1080 ? 1080 : 2160 }
    var shortName: String { self == .p1080 ? "1080p" : "4K" }
}

enum FrameRate: Int, CaseIterable, Codable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}

enum Stabilization: String, CaseIterable, Codable, Identifiable {
    case off, standard, cinematic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .standard: return "Standard"
        case .cinematic: return "Cinematic"
        }
    }
    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        }
    }
}

enum ExposureSetting: String, CaseIterable, Codable, Identifiable {
    case auto, locked
    var id: String { rawValue }
    var label: String { self == .auto ? "Auto" : "Locked (manual)" }
}

enum WhiteBalanceSetting: String, CaseIterable, Codable, Identifiable {
    case auto, locked
    var id: String { rawValue }
    var label: String { self == .auto ? "Auto" : "Locked" }
}

enum FocusSetting: String, CaseIterable, Codable, Identifiable {
    case continuous, locked
    var id: String { rawValue }
    var label: String { self == .continuous ? "Continuous AF" : "Locked lens position" }
}

enum AudioSetting: String, CaseIterable, Codable, Identifiable {
    case spatial, stereo
    var id: String { rawValue }
    var label: String { self == .spatial ? "Spatial (first-order ambisonics)" : "Stereo" }
}

enum CaptureMode: String, CaseIterable, Codable, Identifiable {
    case twoStage
    case realtimeFFV1
    var id: String { rawValue }
    var label: String { self == .twoStage ? "Two-stage (fast stage 1, FFV1 after stop)" : "Real-time FFV1" }
    var shortName: String { self == .twoStage ? "twoStage" : "realtimeFFV1" }
}

enum Stage1CodecChoice: Int, CaseIterable, Codable, Identifiable {
    case raw = 1
    case lz4 = 2
    case lz4Shuffle = 3
    case ffv1Fast = 4
    case utvideo = 5
    var id: Int { rawValue }
    var lcCodec: LCStage1Codec { LCStage1Codec(UInt32(rawValue)) }
    var label: String {
        switch self {
        case .raw: return "Raw planes"
        case .lz4: return "LZ4"
        case .lz4Shuffle: return "LZ4 + byte shuffle"
        case .ffv1Fast: return "FFV1 fast"
        case .utvideo: return "UT Video"
        }
    }
    var shortName: String {
        switch self {
        case .raw: return "raw"
        case .lz4: return "lz4"
        case .lz4Shuffle: return "lz4shuffle"
        case .ffv1Fast: return "ffv1fast"
        case .utvideo: return "utvideo"
        }
    }
}

enum ReferenceRecorderChoice: String, CaseIterable, Codable, Identifiable {
    case auto, movieFileOutput, assetWriter, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (MovieFileOutput, fall back to AssetWriter)"
        case .movieFileOutput: return "AVCaptureMovieFileOutput"
        case .assetWriter: return "AVAssetWriter (VideoToolbox HEVC)"
        case .off: return "Off"
        }
    }
}

enum Preset: String, CaseIterable, Codable, Identifiable {
    case fancy = "Fancy"
    case neutral = "Neutral"
    case custom = "Custom"
    var id: String { rawValue }
}

// MARK: - Settings

struct CaptureSettings: Codable, Equatable {
    var resolution: Resolution = .p2160
    var frameRate: FrameRate = .fps60
    var stabilization: Stabilization = .cinematic
    var hdr: Bool = true

    var exposure: ExposureSetting = .auto
    var shutterSeconds: Double = 1.0 / 120.0
    var iso: Float = 100

    var whiteBalance: WhiteBalanceSetting = .auto
    var temperature: Float = 5600
    var tint: Float = 0

    var focus: FocusSetting = .continuous
    var lensPosition: Float = 0.5

    var audio: AudioSetting = .spatial
    var captureMode: CaptureMode = .twoStage
    var stage1Auto: Bool = true
    var stage1Codec: Stage1CodecChoice = .lz4Shuffle
    var referenceRecorder: ReferenceRecorderChoice = .auto
    var preset: Preset = .fancy

    /// FFV1 final-encode parameters (fixed by the spec, exposed for transparency).
    var ffv1Slices: Int = 24
    var flacCompressionLevel: Int = 5

    static let `default` = CaptureSettings()

    mutating func apply(preset: Preset) {
        switch preset {
        case .fancy:
            stabilization = .cinematic
            hdr = true
            exposure = .auto
            whiteBalance = .auto
            focus = .continuous
        case .neutral:
            stabilization = .off
            hdr = false
            exposure = .locked
            whiteBalance = .locked
            focus = .locked
        case .custom:
            break
        }
        self.preset = preset
    }

    var ffv1Params: LCFfv1Params {
        LCFfv1Params(level: 3, coder: 1, context: 1, slices: Int32(ffv1Slices), slicecrc: 1,
                     threads: Int32(ProcessInfo.processInfo.activeProcessorCount), gop: 1)
    }

    var modeTag: String {
        "\(resolution.shortName)\(frameRate.rawValue)_\(hdr ? "HLG" : "SDR")_\(captureMode.shortName)"
    }
}

// MARK: - Persistence

final class SettingsStore: ObservableObject {
    @Published var settings: CaptureSettings {
        didSet { save() }
    }
    private let key = "LosslessCam.settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(CaptureSettings.self, from: data) {
            settings = s
        } else {
            settings = .default
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
