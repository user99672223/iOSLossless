import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import Combine

/// Owns the AVCaptureSession: device/format selection, the lossless video and
/// audio data outputs, the parallel HEVC reference recorder, live device
/// controls (exposure / white balance / focus), permission handling and —
/// because AVFoundation reports an impossible configuration either by raising
/// an Objective-C exception or by posting a runtime error after the fact —
/// a self-healing recovery ladder that relaxes the configuration step by step
/// (multichannel audio → MovieFileOutput → stabilization) and reports every
/// step to the user and to the diagnostics log.
final class CaptureManager: NSObject, ObservableObject {
    enum State: String { case idle, unauthorized, configuring, running, recording, finishing, interrupted, failed }

    /// Automatic degradations applied so that the session can run on this device.
    struct Fallbacks: Equatable {
        /// 0 = requested multichannel mode, 1 = stereo at most, 2 = no multichannel mode, 3 = no audio input at all.
        var audio = 0
        /// 0 = MovieFileOutput allowed, 1 = HEVC reference through AVAssetWriter only.
        var reference = 0
        /// 0 = requested stabilization, 1 = stabilization off.
        var stabilization = 0

        var isClean: Bool { audio == 0 && reference == 0 && stabilization == 0 }

        var summary: String {
            var parts: [String] = []
            switch audio {
            case 1: parts.append("audio: stereo at most")
            case 2: parts.append("audio: no multichannel mode")
            case 3: parts.append("audio: microphone input disabled")
            default: break
            }
            if reference == 1 { parts.append("reference: AVAssetWriter (MovieFileOutput removed)") }
            if stabilization == 1 { parts.append("stabilization: off") }
            return parts.isEmpty ? "none" : parts.joined(separator: " · ")
        }
    }

    private enum AttemptResult { case ok, retry, failed(String) }

    let session = AVCaptureSession()
    let pipeline = RecordingPipeline()
    let reference = ReferenceRecorder()
    let diagnostics = DiagnosticsLog.shared

    @Published private(set) var state: State = .idle
    @Published private(set) var cameraAuthorized = false
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var activeFormatSummary: String = "—"
    @Published private(set) var activeFormat: FormatOption?
    /// Frame rate the device is actually configured for (may differ from the request when the format cannot do it).
    @Published private(set) var activeFps: Int = 60
    @Published private(set) var catalog = FormatCatalog(device: nil)
    /// Most recent error or recovery message (shown as a dismissible banner).
    @Published var lastError: String?
    /// Standing note about automatic fallbacks / safe mode currently in effect.
    @Published private(set) var advisory: String?
    @Published private(set) var audioModeDescription: String = "—"
    @Published private(set) var referencePathDescription: String = "—"
    @Published private(set) var previewFps: Double = 0
    @Published private(set) var deviceInfo = DeviceInfo()
    @Published private(set) var fallbacks = Fallbacks()
    @Published private(set) var safeModeLevel: Int = 0
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

    private static let inFlightKey = "LosslessCam.configurationInFlight"
    private static let safeModeKey = "LosslessCam.safeModeLevel"

    private let sessionQueue = DispatchQueue(label: "com.losslesscam.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.losslesscam.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.losslesscam.audio", qos: .userInteractive)

    // Session-queue state.
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var currentSettings = CaptureSettings.default
    private var currentFallbacks = Fallbacks()
    private var rejectedFormatIDs = Set<Int>()
    private var pendingFormatID: Int?
    /// Configuration signature → fallbacks that were observed to run without a runtime error.
    private var workingFallbacks: [String: Fallbacks] = [:]
    private var configGeneration = 0
    private var lastCommitTime: Double = 0
    private var runtimeErrorsSinceCommit = 0
    private var inConfiguration = false
    private var configPhase = "idle"
    private var effectiveFps = 60
    private var isRecordingNow = false
    /// Session-queue copy of the applied format (the @Published one belongs to the main thread).
    private var currentOption: FormatOption?
    private var lastAppliedSignature = ""
    private var lastConfigureSucceeded = false
    private var needsRebuildAfterRecording = false
    private var pendingSettings: CaptureSettings?

    // Video-queue state.
    private var previewRate = RateMeter(window: 1.0)
    private var lastPreviewPublish: Double = 0

    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        lc_bridge_init()
        let defaults = UserDefaults.standard
        var level = defaults.integer(forKey: Self.safeModeKey)
        if defaults.bool(forKey: Self.inFlightKey) {
            // The previous launch died while the camera was being configured.
            level = min(level + 1, 3)
            defaults.set(level, forKey: Self.safeModeKey)
            defaults.set(false, forKey: Self.inFlightKey)
            diagnostics.log("launch", "Previous launch ended during camera configuration → safe mode level \(level)")
        }
        safeModeLevel = level
        if level > 0 { advisory = Self.safeModeDescription(level) }

        pipeline.referenceSink = { [weak self] sb, isVideo in self?.reference.append(sampleBuffer: sb, isVideo: isVideo) }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            let err = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.sessionQueue.async { self?.handleRuntimeError(err) }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] n in
            let reason = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            self?.sessionQueue.async { self?.handleInterruption(reason) }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.sessionQueue.async { self?.handleInterruptionEnded() }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session, queue: nil) { [weak self] _ in
            self?.diagnostics.log("session", "Session stopped running")
        })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in
            // Leaving the app is not a crash: never let it count towards safe mode.
            UserDefaults.standard.set(false, forKey: CaptureManager.inFlightKey)
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    static func safeModeDescription(_ level: Int) -> String {
        switch level {
        case 1: return "Safe mode 1 (after a crash during camera setup): spatial/stereo audio modes and MovieFileOutput disabled; reference via AVAssetWriter."
        case 2: return "Safe mode 2 (after repeated crashes during camera setup): additionally video stabilization is off."
        case 3: return "Safe mode 3 (after repeated crashes during camera setup): additionally the microphone input is not attached."
        default: return ""
        }
    }

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
        diagnostics.log("permissions", "camera=\(cam) microphone=\(mic)")
        await MainActor.run {
            cameraAuthorized = cam
            microphoneAuthorized = mic
            if !cam { state = .unauthorized }
        }
    }

    // MARK: Configuration entry points

    /// (Re)configures the session for `settings`. Safe to call while running; while a
    /// recording is in progress the change is deferred until the recording stops.
    func configure(settings: CaptureSettings) {
        sessionQueue.async { [self] in
            if self.isRecordingNow {
                self.pendingSettings = settings
                self.diagnostics.log("capture", "Settings change deferred until the recording stops")
                return
            }
            // Several views observe the same settings; reconfigure only when the format really changed.
            if Self.signature(settings) == self.lastAppliedSignature && self.session.isRunning && self.lastConfigureSucceeded {
                self.currentSettings = settings
                self.applyDeviceControlsOnQueue(settings: settings)
                return
            }
            self.currentSettings = settings
            self.currentFallbacks = self.workingFallbacks[Self.signature(settings)] ?? Fallbacks()
            self.rejectedFormatIDs.removeAll()
            self.configureOnQueue(reason: "settings")
        }
    }

    /// Retries the full configuration from scratch after a failure.
    func retryConfiguration() {
        sessionQueue.async { [self] in
            self.workingFallbacks.removeAll()
            self.currentFallbacks = Fallbacks()
            self.rejectedFormatIDs.removeAll()
            self.tearDownSessionOnQueue()
            self.configureOnQueue(reason: "manual retry")
        }
    }

    /// Clears the persisted safe mode and reconfigures with the full feature set.
    func resetSafeMode() {
        UserDefaults.standard.set(0, forKey: Self.safeModeKey)
        UserDefaults.standard.set(false, forKey: Self.inFlightKey)
        diagnostics.log("launch", "Safe mode reset by the user")
        DispatchQueue.main.async { self.safeModeLevel = 0; self.advisory = nil }
        sessionQueue.async { [self] in
            self.workingFallbacks.removeAll()
            self.currentFallbacks = Fallbacks()
            self.tearDownSessionOnQueue()
            self.configureOnQueue(reason: "safe mode reset")
        }
    }

    private static func signature(_ s: CaptureSettings) -> String {
        "\(s.resolution.rawValue)|\(s.frameRate.rawValue)|\(s.hdr)|\(s.stabilization.rawValue)|\(s.audio.rawValue)|\(s.referenceRecorder.rawValue)"
    }

    // MARK: Configuration (session queue)

    private func applySafeModeFloor() {
        let level = UserDefaults.standard.integer(forKey: Self.safeModeKey)
        if level >= 1 {
            currentFallbacks.audio = max(currentFallbacks.audio, 2)
            currentFallbacks.reference = max(currentFallbacks.reference, 1)
        }
        if level >= 2 { currentFallbacks.stabilization = 1 }
        if level >= 3 { currentFallbacks.audio = 3 }
    }

    private func configureOnQueue(reason: String) {
        DispatchQueue.main.async { self.state = .configuring }
        guard cameraAuthorized else {
            DispatchQueue.main.async { self.state = .unauthorized }
            return
        }
        diagnostics.log("capture", "Configuring (\(reason)): \(Self.signature(currentSettings)) fallbacks[\(currentFallbacks.summary)]")
        // Crash-loop guard: stays set if the process dies before the session proves stable.
        UserDefaults.standard.set(true, forKey: Self.inFlightKey)
        configGeneration += 1
        runtimeErrorsSinceCommit = 0

        var attempts = 0
        while attempts < 8 {
            attempts += 1
            applySafeModeFloor()
            let settings = currentSettings
            var result: AttemptResult = .failed("configuration did not run")
            configPhase = "begin"
            let exception = LCCatchObjCException {
                result = self.attemptConfiguration(settings)
            }
            if let ex = exception {
                diagnostics.log("capture", "Objective-C exception in phase '\(configPhase)': \(ex)")
                if inConfiguration {
                    _ = LCCatchObjCException { self.session.commitConfiguration() }
                    inConfiguration = false
                }
                if escalate(afterExceptionIn: configPhase) {
                    publishError("Camera setup raised an exception in '\(configPhase)'; retrying with \(currentFallbacks.summary)")
                    continue
                }
                finishFailed("Camera setup failed in '\(configPhase)': \(ex)")
                return
            }
            switch result {
            case .ok:
                finishConfigured()
                return
            case .retry:
                continue
            case .failed(let message):
                finishFailed(message)
                return
            }
        }
        finishFailed("Camera setup kept failing after \(attempts) attempts; see Settings → Diagnostics")
    }

    /// One configuration attempt. Runs inside the Objective-C exception boundary;
    /// `configPhase` names the step in progress so an exception can be attributed.
    private func attemptConfiguration(_ settings: CaptureSettings) -> AttemptResult {
        configPhase = "device"
        let device = videoDevice ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device = device else { return .failed("No back wide-angle camera found") }
        videoDevice = device
        let catalog = FormatCatalog(device: device)
        guard let option = chooseFormat(catalog: catalog, settings: settings) else {
            return .failed("Camera offers no usable bi-planar 4:2:0 format for these settings")
        }
        pendingFormatID = option.id

        let stabilizationWanted: Stabilization = currentFallbacks.stabilization == 0 ? settings.stabilization : .off
        let stabMode: AVCaptureVideoStabilizationMode = option.stabilization[stabilizationWanted] == true ? stabilizationWanted.avMode : .off
        let allowMovieOutput = currentFallbacks.reference == 0
        let audioLevel = currentFallbacks.audio
        let wantAudioInput = microphoneAuthorized && audioLevel < 3

        configPhase = "begin"
        session.beginConfiguration()
        inConfiguration = true
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.automaticallyConfiguresApplicationAudioSession = true
        if session.canSetSessionPreset(.inputPriority) { session.sessionPreset = .inputPriority }

        // Camera input (added once).
        configPhase = "video-input"
        if videoInput == nil {
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { commitLocked(); return .failed("Cannot add the camera input to the session") }
                session.addInput(input)
                videoInput = input
            } catch {
                commitLocked()
                return .failed("Camera input: \(error.localizedDescription)")
            }
        }

        // Microphone input.
        configPhase = "audio-input"
        var audioDesc: String
        var info = deviceInfo
        if !wantAudioInput {
            if let ai = audioInput { session.removeInput(ai); audioInput = nil }
            if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
            audioDesc = microphoneAuthorized ? "Microphone input disabled (\(audioLevel >= 3 ? "fallback" : "unavailable"))" : "Microphone not authorized"
        } else {
            if audioInput == nil, let mic = AVCaptureDevice.default(for: .audio) {
                if let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                    session.addInput(input)
                    audioInput = input
                }
            }
            if let ai = audioInput {
                configPhase = "audio-mode"
                let chosen = applyAudioMode(ai, settings: settings, level: audioLevel, info: &info)
                audioDesc = chosen
            } else {
                audioDesc = "No microphone"
            }
        }

        // Lossless video data output (added once).
        configPhase = "video-output"
        if !session.outputs.contains(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.automaticallyConfiguresOutputBufferDimensions = false
            videoOutput.deliversPreviewSizedOutputBuffers = false
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(videoOutput) else { commitLocked(); return .failed("Cannot add the video data output") }
            session.addOutput(videoOutput)
        }
        configPhase = "audio-output"
        if audioInput != nil, !session.outputs.contains(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        }

        // Format, frame rate, colour space.
        configPhase = "format"
        let requestedFps = settings.frameRate.rawValue
        let (minDur, maxDur, fpsUsed) = Self.frameDurations(for: option.format, requestedFps: requestedFps)
        do {
            try device.lockForConfiguration()
        } catch {
            commitLocked()
            return .failed("Format lock: \(error.localizedDescription)")
        }
        let formatException = LCCatchObjCException {
            device.activeFormat = option.format
            device.activeVideoMinFrameDuration = minDur
            device.activeVideoMaxFrameDuration = maxDur
            if settings.hdr && option.supportsHLG {
                device.activeColorSpace = .HLG_BT2020
            } else if option.format.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
        }
        device.unlockForConfiguration()
        if let ex = formatException {
            // This format cannot be applied as requested: try the next best one.
            diagnostics.log("capture", "Format \(option.width)x\(option.height) \(option.fourCC) rejected: \(ex)")
            rejectedFormatIDs.insert(option.id)
            commitLocked()
            return .retry
        }
        effectiveFps = fpsUsed
        if fpsUsed != requestedFps {
            diagnostics.log("capture", "Format \(option.width)x\(option.height) \(option.fourCC) cannot do \(requestedFps) fps; using \(fpsUsed) fps")
        }

        // Native pixel format: never convert in software.
        configPhase = "pixel-format"
        let native = option.pixelFormat
        var pixelNote: String? = nil
        if videoOutput.availableVideoPixelFormatTypes.contains(native) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: native]
        } else if let first = videoOutput.availableVideoPixelFormatTypes.first {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: first]
            pixelNote = "Native format \(option.fourCC) unavailable on the data output; using \(fourCCString(first))"
        }

        // Stabilization on the data output connection (applied by the ISP before delivery).
        configPhase = "stabilization"
        if let conn = videoOutput.connection(with: .video), conn.isVideoStabilizationSupported {
            conn.preferredVideoStabilizationMode = stabMode
        }

        // Reference recorder (MovieFileOutput inside the same session when allowed).
        configPhase = "reference"
        reference.configure(session: session, settings: settings, formatOption: option, allowMovieOutput: allowMovieOutput, stabilization: stabMode)

        configPhase = "commit"
        commitLocked()

        configPhase = "controls"
        applyDeviceControlsOnQueue(settings: settings)

        // Device capability snapshot for the UI (its own exception boundary: a device that
        // is not streaming yet can report white-balance gains the conversion rejects).
        configPhase = "snapshot"
        let f = device.activeFormat
        info.minISO = f.minISO; info.maxISO = f.maxISO
        info.minShutter = max(f.minExposureDuration.seconds, 1.0 / 16000)
        info.maxShutter = max(min(f.maxExposureDuration.seconds, 1.0 / Double(max(fpsUsed, 1))), info.minShutter * 2)
        info.maxWBGain = device.maxWhiteBalanceGain
        info.currentISO = device.iso
        info.currentShutter = device.exposureDuration.seconds
        if let tt = Self.currentTemperatureAndTint(device) {
            info.currentTemperature = tt.temperature
            info.currentTint = tt.tint
        }
        info.currentLensPosition = device.lensPosition
        info.supportsCustomExposure = device.isExposureModeSupported(.custom)
        info.supportsLockedWB = device.isWhiteBalanceModeSupported(.locked) && device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        info.supportsLockedFocus = device.isFocusModeSupported(.locked) && device.isLockingFocusWithCustomLensPositionSupported

        let stabLabel: String
        if stabMode == .off {
            stabLabel = settings.stabilization == .off ? "off" : (currentFallbacks.stabilization == 1 ? "off (fallback)" : "off (unsupported by format)")
        } else {
            stabLabel = stabilizationWanted.label.lowercased()
        }
        let summary = "\(option.width)×\(option.height) @ \(fpsUsed) fps · \(option.fourCC) (\(option.is10Bit ? "10-bit" : "8-bit") \(option.fullRange ? "full" : "video") range) · \(device.activeColorSpace == .HLG_BT2020 ? "HLG BT.2020" : "SDR") · stab \(stabLabel)"
        let refDesc = reference.pathDescription
        let fb = currentFallbacks
        currentOption = option
        DispatchQueue.main.async {
            self.catalog = catalog
            self.activeFormat = option
            self.activeFps = fpsUsed
            self.activeFormatSummary = summary
            self.audioModeDescription = audioDesc
            self.referencePathDescription = refDesc
            self.deviceInfo = info
            self.fallbacks = fb
            if let n = pixelNote { self.lastError = n }
        }
        diagnostics.log("capture", "Configured: \(summary) · audio \(audioDesc) · reference \(reference.path.rawValue)")

        configPhase = "start"
        if !session.isRunning { session.startRunning() }
        return .ok
    }

    private func commitLocked() {
        if inConfiguration {
            session.commitConfiguration()
            inConfiguration = false
        }
    }

    /// Picks the best format for the settings, skipping formats that threw during an earlier attempt.
    private func chooseFormat(catalog: FormatCatalog, settings: CaptureSettings) -> FormatOption? {
        let rejected = rejectedFormatIDs
        if let best = catalog.bestFormat(for: settings), !rejected.contains(best.id) { return best }
        let candidates = catalog.candidates(resolution: settings.resolution, fps: settings.frameRate.rawValue, hdr: settings.hdr).filter { !rejected.contains($0.id) }
        if let c = candidates.first { return c }
        // Closest fallback: same resolution ignoring frame rate / HDR, then anything large.
        let sameRes = catalog.options.filter { $0.width == settings.resolution.width && $0.height == settings.resolution.height && !rejected.contains($0.id) }
        if let c = sameRes.sorted(by: { a, b in
            if (a.isHDRCapable == settings.hdr) != (b.isHDRCapable == settings.hdr) { return a.isHDRCapable == settings.hdr }
            return a.maxFrameRate > b.maxFrameRate
        }).first { return c }
        return catalog.options.filter { !rejected.contains($0.id) }.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    /// Frame durations that are guaranteed to lie inside one of the format's supported ranges.
    static func frameDurations(for format: AVCaptureDevice.Format, requestedFps: Int) -> (CMTime, CMTime, Int) {
        let req = Double(requestedFps)
        let ranges = format.videoSupportedFrameRateRanges
        if let r = ranges.first(where: { req >= $0.minFrameRate - 0.01 && req <= $0.maxFrameRate + 0.01 }) {
            if abs(req - r.maxFrameRate) < 0.01 { return (r.minFrameDuration, r.minFrameDuration, requestedFps) }
            let d = CMTime(value: 1, timescale: CMTimeScale(requestedFps))
            return (d, d, requestedFps)
        }
        // Not supported: use the highest rate the format offers (its own exact duration).
        if let r = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            return (r.minFrameDuration, r.minFrameDuration, Int(r.maxFrameRate.rounded()))
        }
        let d = CMTime(value: 1, timescale: 30)
        return (d, d, 30)
    }

    /// White-balance temperature/tint of the current gains, or nil when the gains are outside the
    /// range the conversion accepts (it raises an exception then).
    static func currentTemperatureAndTint(_ device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceTemperatureAndTintValues? {
        let g = device.deviceWhiteBalanceGains
        let maxG = device.maxWhiteBalanceGain
        for v in [g.redGain, g.greenGain, g.blueGain] where !(v.isFinite && v >= 1 && v <= maxG) { return nil }
        var out: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues? = nil
        let ex = LCCatchObjCException { out = device.temperatureAndTintValues(for: g) }
        guard ex == nil, let tt = out, tt.temperature.isFinite, tt.tint.isFinite else { return nil }
        return tt
    }

    /// Applies the best multichannel audio mode allowed at `level`, trying each candidate inside its own
    /// exception boundary so an unsupported mode degrades instead of crashing.
    private func applyAudioMode(_ ai: AVCaptureDeviceInput, settings: CaptureSettings, level: Int, info: inout DeviceInfo) -> String {
        info.supportsFOA = ai.isMultichannelAudioModeSupported(.firstOrderAmbisonics)
        info.supportsStereo = ai.isMultichannelAudioModeSupported(.stereo)
        let spatialRequested = settings.audio == .spatial
        var candidates: [(name: String, apply: () -> Void, label: String)] = []
        if level == 0 && spatialRequested && info.supportsFOA {
            candidates.append(("firstOrderAmbisonics", { ai.multichannelAudioMode = .firstOrderAmbisonics }, "First-order ambisonics (4 ch)"))
        }
        if level <= 1 && info.supportsStereo {
            let label: String
            if !spatialRequested { label = "Stereo" }
            else if level > 0 { label = "Stereo (spatial disabled by fallback)" }
            else { label = info.supportsFOA ? "Stereo (FOA mode was rejected)" : "Stereo (FOA unsupported on this device)" }
            candidates.append(("stereo", { ai.multichannelAudioMode = .stereo }, label))
        }
        candidates.append(("none", { ai.multichannelAudioMode = .none },
                           level >= 2 ? "Device default (multichannel modes disabled by fallback)" : "Device default (mono)"))
        for c in candidates {
            if let ex = LCCatchObjCException(c.apply) {
                diagnostics.log("audio", "multichannelAudioMode=\(c.name) raised \(ex); trying the next mode")
                continue
            }
            return c.label
        }
        return "Device default"
    }

    private func escalate(afterExceptionIn phase: String) -> Bool {
        switch phase {
        case "audio-input", "audio-mode", "audio-output":
            if currentFallbacks.audio < 3 { currentFallbacks.audio += 1; return true }
        case "reference":
            if currentFallbacks.reference < 1 { currentFallbacks.reference = 1; return true }
        case "stabilization":
            if currentFallbacks.stabilization < 1 { currentFallbacks.stabilization = 1; return true }
        case "format", "pixel-format":
            if let id = pendingFormatID, !rejectedFormatIDs.contains(id) { rejectedFormatIDs.insert(id); return true }
        case "commit", "start", "controls", "snapshot":
            // Culprit unknown: relax in the order most likely to help.
            if audioInput != nil && currentFallbacks.audio < 3 { currentFallbacks.audio += 1; return true }
            if currentFallbacks.reference < 1 { currentFallbacks.reference = 1; return true }
            if currentFallbacks.stabilization < 1 { currentFallbacks.stabilization = 1; return true }
        default:
            break
        }
        return false
    }

    private func finishConfigured() {
        lastCommitTime = CACurrentMediaTime()
        lastAppliedSignature = Self.signature(currentSettings)
        lastConfigureSucceeded = true
        let gen = configGeneration
        let fb = currentFallbacks
        DispatchQueue.main.async {
            if self.state == .configuring || self.state == .failed || self.state == .idle {
                self.state = self.session.isRunning ? .running : .idle
            }
            if !fb.isClean {
                self.advisory = (self.safeModeLevel > 0 ? Self.safeModeDescription(self.safeModeLevel) + " " : "") + "Automatic fallbacks in effect: \(fb.summary)."
            } else if self.safeModeLevel == 0 {
                self.advisory = nil
            }
        }
        // The configuration counts as stable once it has run for a few seconds without a runtime error.
        sessionQueue.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self = self, self.configGeneration == gen, self.runtimeErrorsSinceCommit == 0 else { return }
            // Survived the configuration: a later crash must not be blamed on camera setup.
            UserDefaults.standard.set(false, forKey: Self.inFlightKey)
            if self.session.isRunning {
                self.workingFallbacks[Self.signature(self.currentSettings)] = self.currentFallbacks
                self.diagnostics.log("capture", "Configuration stable (fallbacks: \(self.currentFallbacks.summary))")
            }
        }
    }

    private func finishFailed(_ message: String) {
        lastConfigureSucceeded = false
        UserDefaults.standard.set(false, forKey: Self.inFlightKey)   // a reported failure is not a crash
        diagnostics.log("capture", "FAILED: \(message)")
        DispatchQueue.main.async {
            self.lastError = message
            self.state = .failed
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { self.lastError = message }
    }

    private func tearDownSessionOnQueue() {
        _ = LCCatchObjCException {
            self.session.beginConfiguration()
            for o in self.session.outputs { self.session.removeOutput(o) }
            for i in self.session.inputs { self.session.removeInput(i) }
            self.session.commitConfiguration()
        }
        inConfiguration = false
        videoInput = nil
        audioInput = nil
        reference.detach()
    }

    // MARK: Runtime errors and interruptions (session queue)

    private func handleRuntimeError(_ error: NSError?) {
        runtimeErrorsSinceCommit += 1
        lastConfigureSucceeded = false
        let detail = DiagnosticsLog.describe(error)
        diagnostics.log("session", "Runtime error: \(detail) · running=\(session.isRunning) · \(String(format: "%.1f", CACurrentMediaTime() - lastCommitTime)) s after commit · fallbacks[\(currentFallbacks.summary)]")
        if isRecordingNow {
            // Never tear the graph down under a running recording; the user stops it and we rebuild then.
            needsRebuildAfterRecording = true
            publishError("Camera session error while recording: \(DiagnosticsLog.shortLabel(error)). Stop the recording; the session will be rebuilt.")
            return
        }
        // -11819 AVErrorMediaServicesWereReset: the whole capture graph is gone; rebuild it.
        if error?.domain == AVFoundationErrorDomain && error?.code == -11819 {
            publishError("Media services were reset; rebuilding the camera session")
            tearDownSessionOnQueue()
            configureOnQueue(reason: "media services reset")
            return
        }
        let recent = CACurrentMediaTime() - lastCommitTime < 10
        if recent || !session.isRunning {
            if let step = nextRecoveryStep() {
                currentFallbacks = step.0
                let message = "\(DiagnosticsLog.shortLabel(error)) → \(step.1)"
                diagnostics.log("recovery", message)
                publishError(message)
                configureOnQueue(reason: "recovery")
                return
            }
            finishFailed("Camera session error: \(DiagnosticsLog.shortLabel(error)). Tap Retry, or change resolution / frame rate / stabilization.")
            return
        }
        publishError("Camera session error: \(DiagnosticsLog.shortLabel(error))")
        if !session.isRunning {
            _ = LCCatchObjCException { self.session.startRunning() }
        }
    }

    /// Next, less demanding configuration to try after a runtime error. Order: keep the user's
    /// stabilization but move the HEVC reference out of the session, then give up stabilization.
    private func nextRecoveryStep() -> (Fallbacks, String)? {
        var f = currentFallbacks
        let stabWanted = currentSettings.stabilization != .off && f.stabilization == 0
        if stabWanted && f.reference == 0 {
            f.reference = 1
            return (f, "MovieFileOutput removed; HEVC reference now encoded by AVAssetWriter from the same stabilized frames")
        }
        if stabWanted {
            f.stabilization = 1
            f.reference = currentSettings.referenceRecorder == .assetWriter ? 1 : 0
            return (f, "video stabilization disabled for this format on this device")
        }
        if f.reference == 0 {
            f.reference = 1
            return (f, "MovieFileOutput removed; HEVC reference now encoded by AVAssetWriter")
        }
        if audioInput != nil && f.audio < 3 {
            f.audio += 1
            return (f, f.audio == 3 ? "microphone input disabled" : "multichannel audio mode reduced")
        }
        return nil
    }

    private func handleInterruption(_ reasonValue: Int?) {
        var label = "reason \(reasonValue ?? -1)"
        if let raw = reasonValue, let reason = AVCaptureSession.InterruptionReason(rawValue: raw) {
            switch reason {
            case .videoDeviceNotAvailableInBackground: label = "camera not available in the background"
            case .audioDeviceInUseByAnotherClient: label = "microphone in use by another app"
            case .videoDeviceInUseByAnotherClient: label = "camera in use by another app"
            case .videoDeviceNotAvailableWithMultipleForegroundApps: label = "camera not available with multiple foreground apps"
            case .videoDeviceNotAvailableDueToSystemPressure: label = "camera unavailable due to system pressure (thermal/power)"
            default: break
            }
        }
        diagnostics.log("session", "Interrupted: \(label)")
        DispatchQueue.main.async {
            self.lastError = "Capture interrupted: \(label)"
            if self.state == .running { self.state = .interrupted }
        }
    }

    private func handleInterruptionEnded() {
        diagnostics.log("session", "Interruption ended; running=\(session.isRunning)")
        if !session.isRunning && cameraAuthorized && videoInput != nil {
            _ = LCCatchObjCException { self.session.startRunning() }
        }
        DispatchQueue.main.async {
            if self.state == .interrupted { self.state = self.session.isRunning ? .running : .idle }
        }
    }

    // MARK: Device controls

    /// Exposure / white balance / focus can change without reconfiguring the session.
    func applyDeviceControls(settings: CaptureSettings) {
        sessionQueue.async { [self] in
            self.currentSettings = settings
            self.applyDeviceControlsOnQueue(settings: settings)
        }
    }

    private func applyDeviceControlsOnQueue(settings: CaptureSettings) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.lastError = "Device control: \(error.localizedDescription)" }
            return
        }
        defer { device.unlockForConfiguration() }
        let f = device.activeFormat

        // Exposure
        var exposureLocked = false
        if settings.exposure == .locked && device.isExposureModeSupported(.custom) {
            let secs = min(max(settings.shutterSeconds, f.minExposureDuration.seconds), f.maxExposureDuration.seconds)
            let iso = min(max(settings.iso, f.minISO), f.maxISO)
            if secs.isFinite && iso.isFinite {
                let ex = LCCatchObjCException {
                    device.setExposureModeCustom(duration: CMTime(seconds: secs, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil)
                }
                if let ex = ex { diagnostics.log("controls", "custom exposure raised \(ex); using auto exposure") } else { exposureLocked = true }
            }
        }
        if !exposureLocked && device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        // White balance
        var wbLocked = false
        if settings.whiteBalance == .locked && device.isWhiteBalanceModeSupported(.locked) && device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: settings.temperature, tint: settings.tint)
            let maxG = device.maxWhiteBalanceGain
            func clamp(_ g: Float) -> Float { g.isFinite ? min(max(g, 1), maxG) : 1 }
            let ex = LCCatchObjCException {
                var gains = device.deviceWhiteBalanceGains(for: tt)
                gains.redGain = clamp(gains.redGain)
                gains.greenGain = clamp(gains.greenGain)
                gains.blueGain = clamp(gains.blueGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
            if let ex = ex { diagnostics.log("controls", "locked white balance raised \(ex); using auto") } else { wbLocked = true }
        }
        if !wbLocked && device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }

        // Focus
        var focusLocked = false
        if settings.focus == .locked && device.isFocusModeSupported(.locked) && device.isLockingFocusWithCustomLensPositionSupported {
            let pos = settings.lensPosition.isFinite ? min(max(settings.lensPosition, 0), 1) : 0.5
            let ex = LCCatchObjCException { device.setFocusModeLocked(lensPosition: pos, completionHandler: nil) }
            if let ex = ex { diagnostics.log("controls", "locked focus raised \(ex); using continuous AF") } else { focusLocked = true }
        }
        if !focusLocked && device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }

    /// Current device values (used when the Neutral preset locks exposure/WB/focus).
    func snapshotDeviceValues(into settings: inout CaptureSettings) {
        guard let d = videoDevice else { return }
        let shutter = d.exposureDuration.seconds
        if shutter.isFinite && shutter > 0 { settings.shutterSeconds = shutter }
        if d.iso.isFinite && d.iso > 0 { settings.iso = d.iso }
        if let tt = Self.currentTemperatureAndTint(d) {
            settings.temperature = min(max(tt.temperature, 2000), 10000)
            settings.tint = min(max(tt.tint, -150), 150)
        }
        if d.lensPosition.isFinite { settings.lensPosition = min(max(d.lensPosition, 0), 1) }
    }

    // MARK: Start / stop

    func startRunning() {
        sessionQueue.async { [self] in
            if !self.session.isRunning && self.cameraAuthorized && self.videoInput != nil {
                if let ex = LCCatchObjCException({ self.session.startRunning() }) {
                    self.diagnostics.log("session", "startRunning raised \(ex)")
                    return
                }
                DispatchQueue.main.async { if self.state == .idle { self.state = .running } }
            }
        }
    }

    func stopRunning() {
        sessionQueue.async { [self] in
            if self.session.isRunning && self.state != .recording && self.state != .finishing {
                self.session.stopRunning()
                DispatchQueue.main.async { if self.state == .running { self.state = .idle } }
            }
        }
    }

    // MARK: Recording

    func startRecording(settings: CaptureSettings, stage1Codec: Stage1CodecChoice) {
        sessionQueue.async { [self] in
            guard !isRecordingNow else { return }
            guard let device = videoDevice, let option = currentOption, session.isRunning else {
                self.publishError("Cannot start recording: the camera session is not running")
                return
            }
            // A stage-1 codec that cannot take this bit depth (UT Video is 8-bit only) would drop every frame.
            var stage1Codec = stage1Codec
            if settings.captureMode == .twoStage && lc_stage1_codec_supported(stage1Codec.lcCodec, option.is10Bit ? 2 : 1) == 0 {
                diagnostics.log("record", "Stage-1 codec \(stage1Codec.shortName) cannot encode \(option.is10Bit ? 10 : 8)-bit; using LZ4 + shuffle")
                stage1Codec = .lz4Shuffle
            }
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
                fps: effectiveFps,
                captureMode: settings.captureMode,
                stage1Codec: stage1Codec,
                ffv1: settings.ffv1Params,
                flacLevel: settings.flacCompressionLevel,
                settings: settings,
                referencePath: reference.pathDescription,
                deviceModel: Self.deviceModelIdentifier(),
                audioExpected: audioInput != nil
            )
            let refURL = Recording.documentsDirectory().appendingPathComponent(base + "_HEVC.mov")
            diagnostics.log("record", "Start \(base) · \(option.width)x\(option.height)@\(effectiveFps) \(option.fourCC) · mode \(settings.captureMode.shortName) · stage1 \(stage1Codec.shortName) · reference \(reference.path.rawValue)")
            isRecordingNow = true
            AudioSessionState.shared.captureActive = true
            // Stage 2 / verification of earlier takes must not compete with the stage-1 workers.
            Stage2Runner.shared.setPaused(true)
            pipeline.start(config: config)
            if let ex = LCCatchObjCException({ self.reference.start(url: refURL, firstFrameHint: nil) }) {
                diagnostics.log("record", "Reference start raised \(ex)")
            }
            DispatchQueue.main.async { self.state = .recording }
        }
    }

    func stopRecording(completion: @escaping (Recording?) -> Void) {
        sessionQueue.async { [self] in
            guard isRecordingNow else { DispatchQueue.main.async { completion(nil) }; return }
            DispatchQueue.main.async { self.state = .finishing }
            // Both files end at the same user action: stop lossless ingest first, then the reference.
            pipeline.endIngest()
            reference.stop { [self] refURL, refError in
                self.pipeline.finish(referenceURL: refURL, referenceError: refError) { recording in
                    if let r = recording {
                        self.diagnostics.log("record", "Stop \(r.baseName): \(r.frameCount) frames written, \(r.droppedFrames) dropped, timeline \(String(format: "%.2f", r.durationSeconds)) s")
                    } else {
                        self.diagnostics.log("record", "Stop: nothing recorded")
                    }
                    Stage2Runner.shared.setPaused(false)
                    self.sessionQueue.async {
                        self.isRecordingNow = false
                        AudioSessionState.shared.captureActive = false
                        if self.needsRebuildAfterRecording {
                            self.needsRebuildAfterRecording = false
                            self.tearDownSessionOnQueue()
                            self.configureOnQueue(reason: "rebuild after recording error")
                        } else if let s = self.pendingSettings {
                            self.pendingSettings = nil
                            self.configure(settings: s)
                        }
                    }
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

    /// Hardware model identifier (e.g. "iPhone18,3"); safe to call from any thread.
    static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "iPhone" : identifier
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
