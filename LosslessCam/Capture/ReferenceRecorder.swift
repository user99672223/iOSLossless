import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia

/// Records Apple's own HEVC (Dolby Vision / HLG) reference file from the same
/// capture session. Preferred path: AVCaptureMovieFileOutput inside the
/// session. Fallback: AVAssetWriter fed with the very same sample buffers the
/// lossless pipeline receives, encoded by the hardware HEVC encoder with HLG
/// tagging and automatic HDR metadata insertion.
final class ReferenceRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum Path: String { case movieFileOutput, assetWriter, off }

    private(set) var path: Path = .off
    private var movieOutput: AVCaptureMovieFileOutput?
    private weak var session: AVCaptureSession?
    private var settings = CaptureSettings.default
    private var option: FormatOption?

    // AssetWriter fallback
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var writerStarted = false
    private var writerURL: URL?
    private let writerQueue = DispatchQueue(label: "com.losslesscam.reference")
    private var audioFormatHint: CMFormatDescription?
    private var droppedByWriter: Int64 = 0

    private var stopCompletion: ((URL?, String?) -> Void)?
    private var movieURL: URL?
    private var active = false

    var pathDescription: String {
        switch path {
        case .movieFileOutput: return "AVCaptureMovieFileOutput (HEVC, Dolby Vision / HLG from the session's HDR path)"
        case .assetWriter: return "AVAssetWriter fallback (VideoToolbox HEVC Main10 HLG from the same sample buffers)"
        case .off: return "Reference recording off"
        }
    }

    /// Called inside the session's begin/commitConfiguration block.
    func configure(session: AVCaptureSession, settings: CaptureSettings, formatOption: FormatOption) {
        self.session = session
        self.settings = settings
        self.option = formatOption
        let wantMovie = settings.referenceRecorder == .auto || settings.referenceRecorder == .movieFileOutput
        if settings.referenceRecorder == .off {
            removeMovieOutput(from: session)
            path = .off
            return
        }
        if wantMovie {
            if movieOutput == nil {
                let out = AVCaptureMovieFileOutput()
                out.movieFragmentInterval = .invalid
                if session.canAddOutput(out) {
                    session.addOutput(out)
                    movieOutput = out
                }
            }
            if let out = movieOutput, let conn = out.connection(with: .video) {
                if out.availableVideoCodecTypes.contains(.hevc) {
                    out.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: conn)
                }
                if conn.isVideoStabilizationSupported {
                    conn.preferredVideoStabilizationMode = formatOption.stabilization[settings.stabilization] == true ? settings.stabilization.avMode : .off
                }
                path = .movieFileOutput
                return
            }
            if settings.referenceRecorder == .movieFileOutput {
                // Explicitly requested but impossible on this device/OS.
                removeMovieOutput(from: session)
                path = .off
                return
            }
        }
        removeMovieOutput(from: session)
        path = .assetWriter
    }

    private func removeMovieOutput(from session: AVCaptureSession) {
        if let out = movieOutput, session.outputs.contains(out) { session.removeOutput(out) }
        movieOutput = nil
    }

    // MARK: Start / stop

    func start(url: URL, firstFrameHint: CMSampleBuffer?) {
        active = true
        droppedByWriter = 0
        switch path {
        case .movieFileOutput:
            movieURL = url
            movieOutput?.startRecording(to: url, recordingDelegate: self)
        case .assetWriter:
            writerQueue.async { self.setupWriter(url: url) }
        case .off:
            break
        }
    }

    func stop(completion: @escaping (URL?, String?) -> Void) {
        active = false
        switch path {
        case .movieFileOutput:
            if let out = movieOutput, out.isRecording {
                stopCompletion = completion
                out.stopRecording()
            } else {
                completion(nil, "MovieFileOutput was not recording")
            }
        case .assetWriter:
            writerQueue.async { self.finishWriter(completion: completion) }
        case .off:
            completion(nil, nil)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let completion = stopCompletion
        stopCompletion = nil
        var message: String? = nil
        if let error = error as NSError? {
            // A "recording finished successfully" flag accompanies some non-fatal errors.
            let ok = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            if !ok { message = error.localizedDescription }
        }
        completion?(FileManager.default.fileExists(atPath: outputFileURL.path) ? outputFileURL : nil, message)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {}

    // MARK: AssetWriter fallback

    /// Sample buffers are delivered by the pipeline (video + audio data outputs).
    func append(sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        guard path == .assetWriter, active else { return }
        if !isVideo, audioFormatHint == nil, let fd = CMSampleBufferGetFormatDescription(sampleBuffer) {
            audioFormatHint = fd
        }
        writerQueue.async { self.appendOnQueue(sampleBuffer, isVideo: isVideo) }
    }

    private func setupWriter(url: URL) {
        guard let option = option else { return }
        try? FileManager.default.removeItem(at: url)
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            let fps = settings.frameRate.rawValue
            let pixels = Double(option.width) * Double(option.height)
            // Camera-app-like bit rates: ~ 0.1 bit/pixel/frame at 4K60 HEVC 10-bit.
            let bitrate = Int(pixels * Double(fps) * (option.is10Bit ? 0.11 : 0.08))
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: true
            ]
            var videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(option.width),
                AVVideoHeightKey: Int(option.height)
            ]
            if option.is10Bit && settings.hdr {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
                compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto as String
                videoSettings[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                ]
            } else {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
                videoSettings[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ]
            }
            videoSettings[AVVideoCompressionPropertiesKey] = compression
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vi.expectsMediaDataInRealTime = true
            guard w.canAdd(vi) else { return }
            w.add(vi)

            var ai: AVAssetWriterInput? = nil
            if let hint = audioFormatHint {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(hint)?.pointee
                let channels = Int(asbd?.mChannelsPerFrame ?? 2)
                let rate = asbd?.mSampleRate ?? 48000
                var audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: min(channels, 2),
                    AVEncoderBitRateKey: 256_000
                ]
                if channels > 2 {
                    // AAC reference audio is a stereo monitor mix; the lossless file keeps all channels.
                    audioSettings[AVNumberOfChannelsKey] = 2
                }
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: channels > 2 ? nil : hint)
                input.expectsMediaDataInRealTime = true
                if w.canAdd(input) { w.add(input); ai = input }
            }
            writer = w
            videoInput = vi
            audioInput = ai
            writerStarted = false
            writerURL = url
            if !w.startWriting() {
                writer = nil
            }
        } catch {
            writer = nil
        }
    }

    private func appendOnQueue(_ sb: CMSampleBuffer, isVideo: Bool) {
        guard let w = writer, w.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !writerStarted {
            guard isVideo else { return }   // start the session on the first video frame
            w.startSession(atSourceTime: pts)
            writerStarted = true
        }
        if isVideo {
            if let vi = videoInput, vi.isReadyForMoreMediaData {
                if !vi.append(sb) { droppedByWriter += 1 }
            } else {
                droppedByWriter += 1
            }
        } else if let ai = audioInput, ai.isReadyForMoreMediaData {
            if (CMSampleBufferGetFormatDescription(sb).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2) <= 2 {
                _ = ai.append(sb)
            }
        }
    }

    private func finishWriter(completion: @escaping (URL?, String?) -> Void) {
        guard let w = writer else {
            completion(nil, "AVAssetWriter was not running")
            return
        }
        let url = writerURL
        let dropped = droppedByWriter
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if w.status == .writing && writerStarted {
            w.finishWriting {
                let err = w.error?.localizedDescription
                let note = dropped > 0 ? "AVAssetWriter reference skipped \(dropped) frames (encoder back-pressure)" : nil
                completion(w.status == .completed ? url : nil, err ?? note)
                self.writer = nil
            }
        } else {
            w.cancelWriting()
            writer = nil
            completion(nil, "AVAssetWriter never received a video frame")
        }
    }
}
