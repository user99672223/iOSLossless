import Foundation
import AVFoundation
import CoreMedia

/// One AVCaptureDevice.Format annotated with the properties the UI cares about.
struct FormatOption: Identifiable {
    let id: Int
    let format: AVCaptureDevice.Format
    let width: Int32
    let height: Int32
    let pixelFormat: OSType
    let is10Bit: Bool
    let fullRange: Bool
    let supportsHLG: Bool
    let maxFrameRate: Double
    let minFrameRate: Double
    let binned: Bool
    let fieldOfView: Float
    let stabilization: [Stabilization: Bool]

    var fourCC: String { fourCCString(pixelFormat) }
    var isHDRCapable: Bool { is10Bit && supportsHLG }

    func supports(fps: Int) -> Bool {
        Double(fps) <= maxFrameRate + 0.01 && Double(fps) >= minFrameRate - 0.01
    }
}

func fourCCString(_ code: OSType) -> String {
    let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? String(code)
}

/// Enumerates a camera's formats and answers availability questions for the
/// settings UI (which combinations of resolution / frame rate / HDR /
/// stabilization the device can actually deliver).
final class FormatCatalog {
    let options: [FormatOption]

    init(device: AVCaptureDevice?) {
        var opts: [FormatOption] = []
        if let device = device {
            for (i, f) in device.formats.enumerated() {
                let desc = f.formatDescription
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                let sub = CMFormatDescriptionGetMediaSubType(desc)
                let is10 = sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || sub == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                let is8 = sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                guard is10 || is8 else { continue }   // only bi-planar 4:2:0 formats are losslessly handled
                let full = sub == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                var maxFps = 0.0, minFps = 1000.0
                for r in f.videoSupportedFrameRateRanges {
                    maxFps = max(maxFps, r.maxFrameRate)
                    minFps = min(minFps, r.minFrameRate)
                }
                var stab: [Stabilization: Bool] = [:]
                for s in Stabilization.allCases { stab[s] = f.isVideoStabilizationModeSupported(s.avMode) }
                opts.append(FormatOption(id: i, format: f, width: dims.width, height: dims.height, pixelFormat: sub,
                                         is10Bit: is10, fullRange: full,
                                         supportsHLG: f.supportedColorSpaces.contains(.HLG_BT2020),
                                         maxFrameRate: maxFps, minFrameRate: minFps,
                                         binned: f.isVideoBinned, fieldOfView: f.videoFieldOfView, stabilization: stab))
            }
        }
        options = opts
    }

    /// Candidates for a resolution / fps / HDR choice, best first.
    func candidates(resolution: Resolution, fps: Int, hdr: Bool) -> [FormatOption] {
        let matching = options.filter { o in
            o.width == resolution.width && o.height == resolution.height && o.supports(fps: fps) && (hdr ? o.isHDRCapable : !o.is10Bit)
        }
        // Prefer non-binned, then wider field of view, then video-range (what the ISP natively emits).
        return matching.sorted { a, b in
            if a.binned != b.binned { return !a.binned }
            if a.fieldOfView != b.fieldOfView { return a.fieldOfView > b.fieldOfView }
            if a.fullRange != b.fullRange { return !a.fullRange }
            return a.maxFrameRate > b.maxFrameRate
        }
    }

    func isAvailable(resolution: Resolution, fps: Int, hdr: Bool) -> Bool {
        !candidates(resolution: resolution, fps: fps, hdr: hdr).isEmpty
    }

    func isStabilizationAvailable(_ s: Stabilization, resolution: Resolution, fps: Int, hdr: Bool) -> Bool {
        if s == .off { return true }
        return candidates(resolution: resolution, fps: fps, hdr: hdr).contains { $0.stabilization[s] == true }
    }

    /// Best format for the full settings tuple; stabilization is honoured when
    /// some candidate supports it.
    func bestFormat(for settings: CaptureSettings) -> FormatOption? {
        let c = candidates(resolution: settings.resolution, fps: settings.frameRate.rawValue, hdr: settings.hdr)
        if settings.stabilization != .off, let s = c.first(where: { $0.stabilization[settings.stabilization] == true }) {
            return s
        }
        return c.first
    }

    var summary: String {
        options.map { o in
            "\(o.width)x\(o.height) \(o.fourCC) ≤\(Int(o.maxFrameRate))fps\(o.isHDRCapable ? " HLG" : "")\(o.binned ? " binned" : "")"
        }.joined(separator: "\n")
    }
}
