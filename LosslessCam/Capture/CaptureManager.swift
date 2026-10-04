import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import Combine

/// Owns the AVCaptureSession: device/format selection, the lossless video and
/// audio data outputs, the parallel HEVC reference recorder, live device
/// controls (exposure / white balance / focus) and permission handling.
final class CaptureManager: NSObject, ObservableObject {
    enum State: String { case idle, unauthorized, configuring, running, recording, finishing, failed }

    let session = AVCaptureSession()
    let pipeline = RecordingPipeline()
    let reference = ReferenceRecorder()

    @Published private(set) var state: State = .idle
    @Published private(set) var cameraAuthorized = false
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var activeFormatSummary: String = "—"
    @Published private(set) var activeFormat: FormatOption?
    @Published private(set) var catalog = FormatCatalog(device: nil)
    @Published private(set) var lastError: String?
    @Published private(set) var audioModeDescription: String = "—"
    @Published private(set) var referencePathDescription: String = "—"
    @Published private(set) var previewFps: Double = 0
    @Published private(set) var deviceInfo = DeviceInfo()
    @Published var lastRecording: Recording?

    struct DeviceInfo {
        var minISO: Float = 25
        var maxISO: Float = 3200
        var minShutter: Double = 1.0 / 8000
        var maxShutter: Double = 1.0 / 24
        var maxWBGain: Float = 4
        var currentISO: Float = 100
        var currentShutter: Double = 1.0 / 60
        var currentTemperature: Float = 5600
        var currentTint: Float = 0
        var currentLensPosition: Float = 0.5
        var supportsCustomExposure = true
        var supportsLockedWB = true
        var supportsLockedFocus = true
        var supportsFOA = false
        var supportsStereo = false
    }

    private let sessionQueue = DispatchQueue(label: "com.losslesscam.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.losslesscam.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.losslesscam.audio", qos: .userInteractive)

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var currentSettings = CaptureSettings.default
    private var previewRate = RateMeter(window: 1.0)
    private var lastPreviewPublish: Double = 0
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        lc_bridge_init()
        pipeline.referenceSink = { [weak self] sb, isVideo in self?.reference.append(sampleBuffer: sb, isVideo: isVideo) }
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] n in
            let err = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown"
            self?.lastError = "Session runtime error: \(err)"
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            self?.lastError = "Capture session interrupted"
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: Permissions

    func requestPermissions() async {
        let cam: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cam = true
        case .notDetermined: cam = await AVCaptureDevice.requestAccess(for: .video)
        default: cam = false
        }
        let mic: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = true
        case .notDetermined: mic = await AVCaptureDevice.requestAccess(for: .audio)
        default: mic = false
        }
        await MainActor.run {
            cameraAuthorized = cam
            microphoneAuthorized = mic
            if !cam { state = .unauthorized }
        }
    }

    // MARK: Configuration

    /// (Re)configures the session for `settings`. Safe to call while running.
    func configure(settings: CaptureSettings) {
        currentSettings = settings
        sessionQueue.async { [self] in
            self.configureOnQueue(settings: settings)
        }
    }

    private func configureOnQueue(settings: CaptureSettings) {
        DispatchQueue.main.async { self.state = .configuring }
        guard cameraAuthorized else { return }

        let device = videoDevice ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device = device else {
            fail("No back wide-angle camera found")
            return
        }
        videoDevice = device
        let catalog = FormatCatalog(device: device)
        guard let option = catalog.bestFormat(for: settings) ?? catalog.candidates(resolution: settings.resolution, fps: settings.frameRate.rawValue, hdr: settings.hdr).first
                ?? catalog.options.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            fail("Camera offers no bi-planar 4:2:0 formats")
            return
        }

        session.beginConfiguration()
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.automaticallyConfiguresApplicationAudioSession = true
        if session.canSetSessionPreset(.inputPriority) { session.sessionPreset = .inputPriority }

        // Inputs
        if videoInput == nil {
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) { session.addInput(input); videoInput = input }
                else { session.commitConfiguration(); fail("Cannot add camera input"); return }
            } catch {
                session.commitConfiguration(); fail("Camera input: \(error.localizedDescription)"); return
            }
        }
        if audioInput == nil, microphoneAuthorized, let mic = AVCaptureDevice.default(for: .audio) {
            if let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                session.addInput(input); audioInput = input
            }
        }

        // Spatial / stereo audio mode (iOS 18: first-order ambisonics on supported hardware).
        var audioDesc = "Mono/unknown"
        var info = deviceInfo
        if let ai = audioInput {
            info.supportsFOA = ai.isMultichannelAudioModeSupported(.firstOrderAmbisonics)
            info.supportsStereo = ai.isMultichannelAudioModeSupported(.stereo)
            if settings.audio == .spatial && info.supportsFOA {
                ai.multichannelAudioMode = .firstOrderAmbisonics
                audioDesc = "First-order ambisonics (4 ch)"
            } else if info.supportsStereo {
                ai.multichannelAudioMode = .stereo
                audioDesc = settings.audio == .spatial ? "Stereo (FOA unsupported on this device)" : "Stereo"
            } else {
                ai.multichannelAudioMode = .none
                audioDesc = "Device default"
            }
        } else {
            audioDesc = microphoneAuthorized ? "No microphone" : "Microphone not authorized"
        }

        // Outputs (added once).
        if !session.outputs.contains(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.automaticallyConfiguresOutputBufferDimensions = false
            videoOutput.deliversPreviewSizedOutputBuffers = false
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            else { session.commitConfiguration(); fail("Cannot add video data output"); return }
        }
        if !session.outputs.contains(audioOutput) && audioInput != nil {
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        }

        // Format, frame rate, colour space.
        do {
            try device.lockForConfiguration()
            device.activeFormat = option.format
            let dur = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate.rawValue))
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
            if settings.hdr && option.supportsHLG {
                device.activeColorSpace = .HLG_BT2020
            } else if option.format.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
            device.unlockForConfiguration()
        } catch {
            session.commitConfiguration(); fail("Format lock: \(error.localizedDescription)"); return
        }

        // Native pixel format: never convert in software. The first entry of
        // availableVideoPixelFormatTypes is the most efficient one; we require
        // the device format's own sub type.
        let native = option.pixelFormat
        if videoOutput.availableVideoPixelFormatTypes.contains(native) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: native]
        } else if let first = videoOutput.availableVideoPixelFormatTypes.first {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: first]
            DispatchQueue.main.async { self.lastError = "Native format \(option.fourCC) unavailable on data output; using \(fourCCString(first))" }
        }

        // Stabilization on the data output connection (applied by the ISP before delivery).
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = option.stabilization[settings.stabilization] == true ? settings.stabilization.avMode : .off
            }
        }

        // Reference recorder (MovieFileOutput inside the same session when possible).
        reference.configure(session: session, settings: settings, formatOption: option)

        session.commitConfiguration()
        applyDeviceControlsOnQueue(settings: settings)

        // Device capability snapshot for the UI.
        let f = device.activeFormat
        info.minISO = f.minISO; info.maxISO = f.maxISO
        info.minShutter = max(f.minExposureDuration.seconds, 1.0 / 16000)
        info.maxShutter = min(f.maxExposureDuration.seconds, 1.0 / Double(settings.frameRate.rawValue))
        info.maxWBGain = device.maxWhiteBalanceGain
        info.currentISO = device.iso
        info.currentShutter = device.exposureDuration.seconds
        let tt = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        info.currentTemperature = tt.temperature
        info.currentTint = tt.tint
        info.currentLensPosition = device.lensPosition
        info.supportsCustomExposure = device.isExposureModeSupported(.custom)
        info.supportsLockedWB = device.isWhiteBalanceModeSupported(.locked) && device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        info.supportsLockedFocus = device.isFocusModeSupported(.locked) && device.isLockingFocusWithCustomLensPositionSupported

        let summary = "\(option.width)×\(option.height) @ \(settings.frameRate.rawValue) fps · \(option.fourCC) (\(option.is10Bit ? "10-bit" : "8-bit") \(option.fullRange ? "full" : "video") range) · \(device.activeColorSpace == .HLG_BT2020 ? "HLG BT.2020" : "SDR") · stab \(settings.stabilization.label)"
        let refDesc = reference.pathDescription
        DispatchQueue.main.async {
            self.catalog = catalog
            self.activeFormat = option
            self.activeFormatSummary = summary
            self.audioModeDescription = audioDesc
            self.referencePathDescription = refDesc
            self.deviceInfo = info
            if self.state == .configuring { self.state = self.session.isRunning ? .running : .idle }
        }
        if !session.isRunning {
            session.startRunning()
            DispatchQueue.main.async { self.state = .running }
        }
    }

    /// Exposure / white balance / focus can change without reconfiguring the session.
    func applyDeviceControls(settings: CaptureSettings) {
        currentSettings = settings
        sessionQueue.async { self.applyDeviceControlsOnQueue(settings: settings) }
    }

    private func applyDeviceControlsOnQueue(settings: CaptureSettings) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            // Exposure
            if settings.exposure == .locked && device.isExposureModeSupported(.custom) {
                let f = device.activeFormat
                let secs = min(max(settings.shutterSeconds, f.minExposureDuration.seconds), f.maxExposureDuration.seconds)
                let iso = min(max(settings.iso, f.minISO), f.maxISO)
                device.setExposureModeCustom(duration: CMTime(seconds: secs, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil)
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            // White balance
            if settings.whiteBalance == .locked && device.isWhiteBalanceModeSupported(.locked) && device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: settings.temperature, tint: settings.tint)
                var gains = device.deviceWhiteBalanceGains(for: tt)
                let maxG = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), maxG)
                gains.greenGain = min(max(gains.greenGain, 1), maxG)
                gains.blueGain = min(max(gains.blueGain, 1), maxG)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            // Focus
            if settings.focus == .locked && device.isFocusModeSupported(.locked) && device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: min(max(settings.lensPosition, 0), 1), completionHandler: nil)
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.lastError = "Device control: \(error.localizedDescription)" }
        }
    }

    /// Current device values (used when the Neutral preset locks exposure/WB/focus).
    func snapshotDeviceValues(into settings: inout CaptureSettings) {
        guard let d = videoDevice else { return }
        settings.shutterSeconds = d.exposureDuration.seconds
        settings.iso = d.iso
        let tt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
        settings.temperature = tt.temperature
        settings.tint = tt.tint
        settings.lensPosition = d.lensPosition
    }

    func startRunning() {
        sessionQueue.async {
            if !self.session.isRunning && self.cameraAuthorized && self.videoInput != nil {
                self.session.startRunning()
                DispatchQueue.main.async { self.state = .running }
            }
        }
    }

    func stopRunning() {
        sessionQueue.async {
            if self.session.isRunning && self.state != .recording {
                self.session.stopRunning()
                DispatchQueue.main.async { self.state = .idle }
            }
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.lastError = message
            self.state = .failed
        }
    }

    // MARK: Recording

    func startRecording(settings: CaptureSettings, stage1Codec: Stage1CodecChoice) {
        sessionQueue.async { [self] in
            guard let device = videoDevice, let option = activeFormat else { return }
            let stamp = Self.timestamp()
            let base = "LosslessCam_\(stamp)_\(settings.preset.rawValue)_\(settings.modeTag)"
            let colour = ColourInfo.from(device: device, option: option)
            let config = RecordingPipeline.Config(
                baseName: base,
                width: Int(option.width), height: Int(option.height),
                bytesPerSample: option.is10Bit ? 2 : 1,
                fullRange: option.fullRange,
                pixelFormatFourCC: option.fourCC,
                colour: colour,
                fps: settings.frameRate.rawValue,
                captureMode: settings.captureMode,
                stage1Codec: stage1Codec,
                ffv1: settings.ffv1Params,
                flacLevel: settings.flacCompressionLevel,
                settings: settings,
                referencePath: reference.pathDescription,
                deviceModel: UIDevice.current.model
            )
            let refURL = Recording.documentsDirectory().appendingPathComponent(base + "_HEVC.mov")
            pipeline.start(config: config)
            reference.start(url: refURL, firstFrameHint: nil)
            DispatchQueue.main.async { self.state = .recording }
        }
    }

    func stopRecording(completion: @escaping (Recording?) -> Void) {
        sessionQueue.async { [self] in
            DispatchQueue.main.async { self.state = .finishing }
            reference.stop { [self] refURL, refError in
                self.pipeline.stop(referenceURL: refURL, referenceError: refError) { recording in
                    DispatchQueue.main.async {
                        self.lastRecording = recording
                        self.state = self.session.isRunning ? .running : .idle
                        completion(recording)
                    }
                }
            }
        }
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

// MARK: - Sample buffer delegates

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            let now = CACurrentMediaTime()
            previewRate.add(1, at: now)
            if now - lastPreviewPublish > 0.5 {
                lastPreviewPublish = now
                let fps = previewRate.rate(at: now)
                DispatchQueue.main.async { self.previewFps = fps }
            }
            pipeline.ingestVideo(sampleBuffer)
        } else if output === audioOutput {
            pipeline.ingestAudio(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            var reason = "unknown"
            if let att = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) {
                reason = String(describing: att)
            }
            pipeline.noteSourceDrop(reason: reason)
        }
    }
}

/// Colour metadata derived from the active device colour space and pixel format.
struct ColourInfo {
    var primaries: Int32
    var transfer: Int32
    var matrix: Int32
    var chromaLocation: Int32
    var isHDR: Bool
    var description: String

    static func from(device: AVCaptureDevice, option: FormatOption) -> ColourInfo {
        switch device.activeColorSpace {
        case .HLG_BT2020:
            return ColourInfo(primaries: Int32(LC_COLOR_PRI_BT2020), transfer: Int32(LC_COLOR_TRC_ARIB_STD_B67),
                              matrix: Int32(LC_COLOR_SPC_BT2020_NCL), chromaLocation: Int32(LC_CHROMA_LOC_LEFT),
                              isHDR: true, description: "BT.2020 / HLG (ARIB STD-B67) / BT.2020 NCL")
        case .P3_D65:
            return ColourInfo(primaries: Int32(LC_COLOR_PRI_SMPTE432), transfer: Int32(LC_COLOR_TRC_BT709),
                              matrix: Int32(LC_COLOR_SPC_BT709), chromaLocation: Int32(LC_CHROMA_LOC_LEFT),
                              isHDR: false, description: "Display P3 (SMPTE 432) / BT.709 transfer / BT.709 matrix")
        default:
            return ColourInfo(primaries: Int32(LC_COLOR_PRI_BT709), transfer: Int32(LC_COLOR_TRC_BT709),
                              matrix: Int32(LC_COLOR_SPC_BT709), chromaLocation: Int32(LC_CHROMA_LOC_LEFT),
                              isHDR: false, description: "BT.709 / BT.709 / BT.709")
        }
    }
}
