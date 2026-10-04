import Foundation
import AVFoundation
import CoreVideo
import CoreMedia

/// Stream description shared by the FFV1 (libavcodec) and HEVC (AVFoundation) sources.
struct MediaInfo {
    var width: Int
    var height: Int
    var bitDepth: Int
    var fullRange: Bool
    var fps: Double
    var frameCount: Int64
    var frameCountExact: Bool
    var durationNs: Int64
    var videoCodec: String
    var audioCodec: String?
    var sampleRate: Int
    var channels: Int
    var ambisonic: Bool
    var isHDR: Bool
    var colorPrimaries: Int32
    var colorTransfer: Int32
    var colorMatrix: Int32
    var container: String
    var ffv1Version: Int
    var sliceCrc: Bool

    var frameDurationNs: Int64 { fps > 0 ? Int64(1e9 / fps) : 16_666_667 }
    var pixelFormat: OSType { bitDepth == 10 ? (fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                                             : (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }
    var colorLabel: String {
        let pri = colorPrimaries == Int32(LC_COLOR_PRI_BT2020) ? "BT.2020" : (colorPrimaries == Int32(LC_COLOR_PRI_SMPTE432) ? "P3" : "BT.709")
        let trc = colorTransfer == Int32(LC_COLOR_TRC_ARIB_STD_B67) ? "HLG" : (colorTransfer == Int32(LC_COLOR_TRC_SMPTE2084) ? "PQ" : "BT.709")
        return "\(pri) \(trc) \(fullRange ? "full" : "video")-range \(bitDepth)-bit"
    }
}

/// A decoded frame as an IOSurface-backed CVPixelBuffer in the capture layout
/// (x420 / 420v), tagged with its colour attachments.
final class DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let index: Int64
    let ptsNs: Int64
    init(pixelBuffer: CVPixelBuffer, index: Int64, ptsNs: Int64) {
        self.pixelBuffer = pixelBuffer
        self.index = index
        self.ptsNs = ptsNs
    }
}

protocol FrameSource: AnyObject {
    var info: MediaInfo { get }
    var url: URL { get }
    func pts(ofFrame index: Int64) -> Int64
    func frameIndex(forPts ptsNs: Int64) -> Int64
    /// Blocking decode. Call from a single decode thread per source.
    func frame(at index: Int64) -> DecodedFrame?
    var crcErrors: Int { get }
}

/// Pool of Metal-compatible CVPixelBuffers in the capture layout.
final class PixelBufferPool {
    private var pool: CVPixelBufferPool?
    let width: Int, height: Int, pixelFormat: OSType
    let isHDR: Bool
    let fullRange: Bool

    init(width: Int, height: Int, pixelFormat: OSType, isHDR: Bool, fullRange: Bool) {
        self.width = width; self.height = height; self.pixelFormat = pixelFormat; self.isHDR = isHDR; self.fullRange = fullRange
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &p)
        pool = p
    }

    func make() -> CVPixelBuffer? {
        guard let pool = pool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let out = pb else { return nil }
        tag(out)
        return out
    }

    /// HLG BT.2020 or BT.709 colour attachments so any consumer interprets the buffer correctly.
    func tag(_ pb: CVPixelBuffer) {
        if isHDR {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        } else {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
    }
}

// MARK: - FFV1 / MKV via libavcodec

final class FFV1FrameSource: FrameSource {
    let info: MediaInfo
    let url: URL
    private let dec: OpaquePointer
    private var nextIndex: Int64 = 0
    private let pool: PixelBufferPool
    private let lock = NSLock()

    init?(url: URL) {
        self.url = url
        var err = [CChar](repeating: 0, count: 256)
        guard let d = lc_decoder_open(url.path, 1, 1, Int32(ProcessInfo.processInfo.activeProcessorCount), &err, err.count) else {
            return nil
        }
        var li = LCMediaInfo()
        lc_decoder_get_info(d, &li)
        guard li.has_video != 0 else { lc_decoder_close(d); return nil }
        let fps = li.fps_den > 0 ? Double(li.fps_num) / Double(li.fps_den) : 30
        let isHDR = li.color_trc == Int32(LC_COLOR_TRC_ARIB_STD_B67) || li.color_trc == Int32(LC_COLOR_TRC_SMPTE2084)
        var liCopy = li
        let vcodec = withUnsafePointer(to: &liCopy.video_codec) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        let acodec = withUnsafePointer(to: &liCopy.audio_codec) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        let container = withUnsafePointer(to: &liCopy.container) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        info = MediaInfo(width: Int(li.width), height: Int(li.height), bitDepth: Int(li.bit_depth), fullRange: li.full_range != 0,
                         fps: fps, frameCount: max(li.frame_count, 1), frameCountExact: li.frame_count_exact != 0,
                         durationNs: li.duration_ns, videoCodec: vcodec, audioCodec: li.has_audio != 0 ? acodec : nil,
                         sampleRate: Int(li.sample_rate), channels: Int(li.channels), ambisonic: li.audio_ambisonic != 0,
                         isHDR: isHDR, colorPrimaries: li.color_primaries, colorTransfer: li.color_trc, colorMatrix: li.colorspace,
                         container: container, ffv1Version: Int(li.ffv1_version), sliceCrc: li.ffv1_slicecrc != 0)
        dec = d
        pool = PixelBufferPool(width: info.width, height: info.height, pixelFormat: info.pixelFormat, isHDR: isHDR, fullRange: info.fullRange)
    }

    deinit { lc_decoder_close(dec) }

    var crcErrors: Int { Int(lc_decoder_crc_errors(dec)) }

    func pts(ofFrame index: Int64) -> Int64 { lc_decoder_frame_pts(dec, index) }
    func frameIndex(forPts ptsNs: Int64) -> Int64 { lc_decoder_frame_index_for_pts(dec, ptsNs) }

    func frame(at index: Int64) -> DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        let idx = min(max(index, 0), info.frameCount - 1)
        if idx != nextIndex {
            guard lc_decoder_seek_frame(dec, idx) == 0 else { return nil }
        }
        var f = LCVideoFrame()
        let r = lc_decoder_next_video(dec, &f)
        guard r == 1 else { nextIndex = -1; return nil }
        nextIndex = f.index + 1
        guard let pb = pool.make() else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dy = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let dc = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let dys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), dcs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        if f.pix_fmt == LC_PIX_YUV420P10 {
            lc_repack_yuv420p10_to_p010(f.planes.0, f.strides.0, f.planes.1, f.strides.1, f.planes.2, f.strides.2, f.width, f.height,
                                        dy.assumingMemoryBound(to: UInt8.self), dys, dc.assumingMemoryBound(to: UInt8.self), dcs)
        } else {
            lc_repack_yuv420p_to_nv12(f.planes.0, f.strides.0, f.planes.1, f.strides.1, f.planes.2, f.strides.2, f.width, f.height,
                                      dy.assumingMemoryBound(to: UInt8.self), dys, dc.assumingMemoryBound(to: UInt8.self), dcs)
        }
        return DecodedFrame(pixelBuffer: pb, index: f.index, ptsNs: f.pts_ns)
    }
}

// MARK: - HEVC / MOV via AVAssetReader (hardware decode)

final class HEVCFrameSource: FrameSource {
    let info: MediaInfo
    let url: URL
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var nextIndex: Int64 = -1
    private let lock = NSLock()
    private let pixelFormat: OSType
    private let pool: PixelBufferPool
    var crcErrors: Int { 0 }

    init?(url: URL) {
        self.url = url
        let asset = AVURLAsset(url: url)
        self.asset = asset
        // Load track properties synchronously (we are never on the main thread here).
        final class LoadBox: @unchecked Sendable {
            var track: AVAssetTrack?
            var fps: Float = 30
            var size = CGSize.zero
            var durationNs: Int64 = 0
            var formatDesc: CMFormatDescription?
        }
        let box = LoadBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            if let t = try? await asset.loadTracks(withMediaType: .video).first {
                box.track = t
                if let loaded = try? await t.load(.nominalFrameRate, .naturalSize, .formatDescriptions) {
                    box.fps = loaded.0
                    box.size = loaded.1
                    box.formatDesc = loaded.2.first
                }
            }
            if let d = try? await asset.load(.duration) {
                box.durationNs = Int64(CMTimeConvertScale(d, timescale: 1_000_000_000, method: .default).value)
            }
            sem.signal()
        }
        sem.wait()
        guard let t = box.track else { return nil }
        track = t
        let fps = box.fps
        let size = box.size
        let durationNs = box.durationNs
        let formatDesc = box.formatDesc
        var bits = 8
        var primaries = Int32(LC_COLOR_PRI_BT709), transfer = Int32(LC_COLOR_TRC_BT709), matrix = Int32(LC_COLOR_SPC_BT709)
        var fullRange = false
        var codec = "hevc"
        if let fd = formatDesc {
            if let b = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int { bits = b }
            if let tf = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                if tf == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) { transfer = Int32(LC_COLOR_TRC_ARIB_STD_B67); if bits == 8 { bits = 10 } }
                else if tf == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) { transfer = Int32(LC_COLOR_TRC_SMPTE2084); if bits == 8 { bits = 10 } }
            }
            if let p = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
               p == (kCVImageBufferColorPrimaries_ITU_R_2020 as String) { primaries = Int32(LC_COLOR_PRI_BT2020) }
            if let m = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String,
               m == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { matrix = Int32(LC_COLOR_SPC_BT2020_NCL) }
            if let fr = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool { fullRange = fr }
            codec = fourCCString(CMFormatDescriptionGetMediaSubType(fd))
        }
        let isHDR = transfer == Int32(LC_COLOR_TRC_ARIB_STD_B67) || transfer == Int32(LC_COLOR_TRC_SMPTE2084)
        let frameCount = fps > 0 ? Int64((Double(durationNs) / 1e9 * Double(fps)).rounded()) : 0
        pixelFormat = bits == 10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        info = MediaInfo(width: Int(size.width), height: Int(size.height), bitDepth: bits, fullRange: fullRange, fps: Double(fps),
                         frameCount: max(frameCount, 1), frameCountExact: false, durationNs: durationNs, videoCodec: codec,
                         audioCodec: nil, sampleRate: 0, channels: 0, ambisonic: false, isHDR: isHDR,
                         colorPrimaries: primaries, colorTransfer: transfer, colorMatrix: matrix, container: "mov", ffv1Version: 0, sliceCrc: false)
        pool = PixelBufferPool(width: info.width, height: info.height, pixelFormat: pixelFormat, isHDR: isHDR, fullRange: fullRange)
    }

    func pts(ofFrame index: Int64) -> Int64 { Int64((Double(index) * 1e9 / info.fps).rounded()) }
    func frameIndex(forPts ptsNs: Int64) -> Int64 { max(0, Int64((Double(ptsNs) / 1e9 * info.fps).rounded())) }

    private func restart(at ptsNs: Int64) -> Bool {
        reader?.cancelReading()
        guard let r = try? AVAssetReader(asset: asset) else { return false }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { return false }
        r.add(out)
        let start = CMTime(value: CMTimeValue(max(ptsNs, 0)), timescale: 1_000_000_000)
        r.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        guard r.startReading() else { return false }
        reader = r
        output = out
        return true
    }

    func frame(at index: Int64) -> DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        let idx = min(max(index, 0), info.frameCount - 1)
        let target = pts(ofFrame: idx)
        if reader == nil || idx != nextIndex || reader?.status != .reading {
            guard restart(at: target) else { return nil }
        }
        guard let out = output else { return nil }
        let half = info.frameDurationNs / 2
        var attempts = 0
        while attempts < 600 {
            attempts += 1
            guard let sb = out.copyNextSampleBuffer() else {
                nextIndex = -1
                return nil
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let ptsNs = Int64(CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value)
            if ptsNs < target - half { continue }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            pool.tag(pb)
            nextIndex = idx + 1
            return DecodedFrame(pixelBuffer: pb, index: idx, ptsNs: ptsNs)
        }
        return nil
    }
}

/// Opens the right source for a file extension.
func makeFrameSource(url: URL) -> FrameSource? {
    let ext = url.pathExtension.lowercased()
    if ext == "mov" || ext == "mp4" || ext == "m4v" {
        return HEVCFrameSource(url: url) ?? FFV1FrameSource(url: url)
    }
    return FFV1FrameSource(url: url)
}
