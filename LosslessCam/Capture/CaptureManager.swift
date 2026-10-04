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
/// a self-healing recovery ladder that removes one suspect at a time
/// (in-session HEVC MovieFileOutput, stabilization, multichannel audio), then
/// combinations, and reports every step to the user and the diagnostics log.
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
        /// 0 = second (stereo) audio data output for the AVAssetWriter reference allowed while the
        /// lossless output takes first-order ambisonics, 1 = no second output (reference without audio).
        var referenceAudio = 0

        var isClean: Bool { audio == 0 && reference == 0 && stabilization == 0 && referenceAudio == 0 }

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
            if referenceAudio == 1 { parts.append("reference: no stereo audio while spatial audio is captured") }
            return parts.isEmpty ? "none" : parts.joined(separator: " · ")
        }
    }

    private enum AttemptResult { case ok, retry, failed(String) }

    /// The live capture session. When the outermost commitConfiguration raises, AVFoundation
    /// neither applies the changes nor closes the configuration block, so the session stays
    /// "between beginConfiguration and commitConfiguration" for good and every later
    /// startRunning raises. Such a session is replaced, never repaired. Readable from any
    /// thread; replaced only on the session queue (`replaceSession`).
    private let sessionBox = SessionBox()
    var session: AVCaptureSession { sessionBox.value }
    /// Incremented on the main thread whenever `session` is replaced, so the preview re-attaches.
    @Published private(set) var sessionVersion = 0
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
    private let referenceAudioQueue = DispatchQueue(label: "com.losslesscam.reference-audio", qos: .userInitiated)

    // Session-queue state. Outputs belong to one session for life, so they are recreated
    // together with the session; the sample-buffer delegates never compare against these
    // references (they are replaced on the session queue while callbacks run elsewhere).
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var videoOutput = AVCaptureVideoDataOutput()
    private var audioOutput = AVCaptureAudioDataOutput()
    /// Stereo audio data output that feeds only the AVAssetWriter reference while `audioOutput`
    /// delivers first-order ambisonics (iOS 26 allows exactly one FOA and one stereo output then).
    private var referenceAudioOutput: AVCaptureAudioDataOutput?
    private lazy var referenceAudioTap = ReferenceAudioTap(reference: reference)
    private var sessionReplacements = 0
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
    private var stopInProgress = false
    /// Foreground state for the crash-loop guard (written on main, read on the session queue).
    private let appActive = AtomicFlag()
    /// Session-queue copy of the applied format (the @Published one belongs to the main thread).
    private var currentOption: FormatOption?
    private var lastAppliedSignature = ""
    private var lastConfigureSucceeded = false
    private var needsRebuildAfterRecording = false
    private var pendingSettings: CaptureSettings?
    /// Configuration generation visible to the notification threads, so a runtime error can be
    /// attributed to the configuration that was active when it was posted.
    private let generationBox = AtomicInt()
    /// Recovery ladder for runtime errors: candidate fallbacks tried one cause at a time, then
    /// in combination. Rebuilt when the requested settings change.
    private var ladder: [(Fallbacks, String)] = []
    private var ladderIndex = -1
    private var ladderBase = Fallbacks()
    private var mediaResetsNearCommit = 0
    private var lateRestartAt: Double = -1000
    // What the applied configuration actually uses (only these can be causes of a runtime error).
    private var appliedMovieOutput = false
    private var appliedStabilization = false
    private var appliedMultichannel = false
    private var appliedFOA = false
    private var appliedReferenceAudioOutput = false

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

        // Session notifications are observed for any sender and filtered by identity: the session
        // object is replaced after a failed commit, and a discarded one must not be reported.
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] n in
            guard let self = self, let sender = n.object as? AVCaptureSession, sender === self.session else { return }
            let err = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let gen = self.generationBox.value
            self.sessionQueue.async { self.handleRuntimeError(err, generation: gen) }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: nil) { [weak self] n in
            guard let self = self, let sender = n.object as? AVCaptureSession, sender === self.session else { return }
            let reason = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            self.sessionQueue.async { self.handleInterruption(reason) }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: nil) { [weak self] n in
            guard let self = self, let sender = n.object as? AVCaptureSession, sender === self.session else { return }
            self.sessionQueue.async { self.handleInterruptionEnded() }
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: nil, queue: nil) { [weak self] n in
            guard let self = self, let sender = n.object as? AVCaptureSession, sender === self.session else { return }
            self.diagnostics.log("session", "Session stopped running")
        })
        appActive.value = UIApplication.shared.applicationState == .active
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.appActive.value = true
        })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            // Leaving the app is not a crash: never let it count towards safe mode.
            self?.appActive.value = false
            UserDefaults.standard.set(false, forKey: CaptureManager.inFlightKey)
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
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
            self.resetLadder()
            self.configureOnQueue(reason: "settings")
        }
    }

    /// Retries the full configuration from scratch after a failure.
    func retryConfiguration() {
        sessionQueue.async { [self] in
            self.workingFallbacks.removeAll()
            self.currentFallbacks = Fallbacks()
            self.rejectedFormatIDs.removeAll()
            self.resetLadder()
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
            self.resetLadder()
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
        // Only armed in the foreground: a suspended app killed by iOS has not crashed.
        if appActive.value { UserDefaults.standard.set(true, forKey: Self.inFlightKey) }
        configGeneration += 1
        generationBox.value = configGeneration
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
                let phase = configPhase
                diagnostics.log("capture", "Objective-C exception in phase '\(phase)': \(ex)")
                // The session is unusable when its configuration block cannot be closed: the
                // outermost commit validates the whole graph, and a commit that raises leaves the
                // block open, so every later startRunning raises "between beginConfiguration and
                // commitConfiguration". Try to close it once; if that raises too, replace the session.
                let stateSymptom = Self.isConfigurationStateException(ex)
                var poisoned = stateSymptom
                if inConfiguration {
                    if let again = LCCatchObjCException({ self.session.commitConfiguration() }) {
                        diagnostics.log("capture", "Closing the configuration block raised as well: \(Self.firstLine(again))")
                        poisoned = true
                    } else {
                        inConfiguration = false
                    }
                }
                if poisoned {
                    replaceSession(reason: "configuration block could not be closed after '\(phase)'", configurationOpen: true)
                }
                if stateSymptom {
                    // Caused by the session state, not by the requested graph: retry it unchanged
                    // on the fresh session (bounded by the attempt limit).
                    continue
                }
                if escalate(afterExceptionIn: phase, message: ex) {
                    publishError("Camera setup: \(Self.firstLine(ex)) — retrying with \(currentFallbacks.summary)")
                    continue
                }
                finishFailed("Camera setup failed in '\(phase)': \(ex)")
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
        appliedMultichannel = false
        appliedFOA = false
        appliedReferenceAudioOutput = false
        if !wantAudioInput {
            if let ai = audioInput { session.removeInput(ai); audioInput = nil }
            if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
            removeReferenceAudioOutput()
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
                audioDesc = chosen.label
                appliedMultichannel = chosen.multichannel
                appliedFOA = chosen.foa
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
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            } else {
                diagnostics.log("audio", "Session refused the audio data output (canAddOutput == false); recording without audio")
            }
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
        appliedMovieOutput = reference.path == .movieFileOutput
        appliedStabilization = stabMode != .off

        // While the lossless output takes 4-channel ambisonics, the AVAssetWriter reference gets
        // its own stereo output (AAC cannot carry the FOA layout). MovieFileOutput records its
        // own FOA + stereo tracks and needs none.
        configPhase = "reference-audio"
        configureReferenceAudioOutput(wanted: appliedFOA && audioInput != nil && reference.path == .assetWriter && currentFallbacks.referenceAudio == 0)
        if appliedFOA && reference.path == .assetWriter && !appliedReferenceAudioOutput {
            audioDesc += " · HEVC reference without audio"
        }

        configPhase = "commit"
        commitLocked()

        configPhase = "controls"
        applyDeviceControlsOnQueue(settings: settings)   // has its own exception boundary

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
        configPhase = "summary"

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
    ///
    /// iOS 26 validates the audio data outputs against the mode at commit (AVCaptureAudioDataOutput.h):
    /// with first-order ambisonics every connected audio data output needs a spatial layout tag
    /// (`kAudioChannelLayoutTag_HOA_ACN_SN3D | 4` or `kAudioChannelLayoutTag_Stereo`), with any other
    /// mode the tag must stay `kAudioChannelLayoutTag_Unknown`. An untagged output in FOA mode makes the
    /// commit raise NSInvalidArgumentException. Each candidate therefore sets mode and tag together.
    private func applyAudioMode(_ ai: AVCaptureDeviceInput, settings: CaptureSettings, level: Int, info: inout DeviceInfo) -> (label: String, multichannel: Bool, foa: Bool) {
        info.supportsFOA = ai.isMultichannelAudioModeSupported(.firstOrderAmbisonics)
        info.supportsStereo = ai.isMultichannelAudioModeSupported(.stereo)
        let spatialRequested = settings.audio == .spatial
        let output = audioOutput
        var candidates: [(name: String, apply: () -> Void, label: String)] = []
        if level == 0 && spatialRequested && info.supportsFOA {
            candidates.append(("firstOrderAmbisonics", {
                ai.multichannelAudioMode = .firstOrderAmbisonics
                if #available(iOS 26.0, *) {
                    output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
                }
            }, "First-order ambisonics (4 ch, ACN/SN3D)"))
        }
        if level <= 1 && info.supportsStereo {
            let label: String
            if !spatialRequested { label = "Stereo" }
            else if level > 0 { label = "Stereo (spatial disabled by fallback)" }
            else { label = info.supportsFOA ? "Stereo (FOA mode was rejected)" : "Stereo (FOA unsupported on this device)" }
            candidates.append(("stereo", {
                ai.multichannelAudioMode = .stereo
                if #available(iOS 26.0, *) {
                    output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_Unknown
                }
            }, label))
        }
        candidates.append(("none", {
            ai.multichannelAudioMode = .none
            if #available(iOS 26.0, *) {
                output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_Unknown
            }
        }, level >= 2 ? "Device default (multichannel modes disabled by fallback)" : "Device default (mono)"))
        for c in candidates {
            if let ex = LCCatchObjCException(c.apply) {
                diagnostics.log("audio", "multichannelAudioMode=\(c.name) raised \(ex); trying the next mode")
                continue
            }
            diagnostics.log("audio", "multichannelAudioMode=\(c.name)\(Self.layoutTagNote(output))")
            return (c.label, c.name != "none", c.name == "firstOrderAmbisonics")
        }
        return ("Device default", false, false)
    }

    private static func layoutTagNote(_ output: AVCaptureAudioDataOutput) -> String {
        if #available(iOS 26.0, *) {
            return String(format: " · output layout tag 0x%08X", output.spatialAudioChannelLayoutTag)
        }
        return ""
    }

    /// Adds or removes the stereo audio data output that feeds the AVAssetWriter reference while
    /// the lossless output takes first-order ambisonics. Runs inside the configuration block.
    private func configureReferenceAudioOutput(wanted: Bool) {
        if #available(iOS 26.0, *), wanted {
            let out = referenceAudioOutput ?? AVCaptureAudioDataOutput()
            out.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            if session.outputs.contains(out) {
                appliedReferenceAudioOutput = true
            } else {
                out.setSampleBufferDelegate(referenceAudioTap, queue: referenceAudioQueue)
                if session.canAddOutput(out) {
                    session.addOutput(out)
                    referenceAudioOutput = out
                    appliedReferenceAudioOutput = true
                } else {
                    out.setSampleBufferDelegate(nil, queue: nil)
                    referenceAudioOutput = nil
                    diagnostics.log("audio", "Session refused a second (stereo) audio data output; the HEVC reference records without audio")
                }
            }
        } else {
            removeReferenceAudioOutput()
        }
        reference.setDedicatedAudio(appliedReferenceAudioOutput)
    }

    private func removeReferenceAudioOutput() {
        if let out = referenceAudioOutput {
            if session.outputs.contains(out) { session.removeOutput(out) }
            out.setSampleBufferDelegate(nil, queue: nil)
            referenceAudioOutput = nil
        }
        appliedReferenceAudioOutput = false
        reference.setDedicatedAudio(false)
    }

    /// Picks the fallback that addresses the exception. AVFoundation names the offending object in
    /// the reason (e.g. "multichannelAudioMode … AVCaptureAudioDataOutput spatialAudioChannelLayoutTag"),
    /// so the message decides before the phase does; this keeps an audio fault from switching off
    /// stabilization or the in-session HEVC encoder.
    private func escalate(afterExceptionIn phase: String, message: String) -> Bool {
        let m = message.lowercased()
        let audioRelated = phase.hasPrefix("audio") || phase == "reference-audio"
            || m.contains("multichannelaudiomode") || m.contains("spatialaudiochannellayouttag")
            || m.contains("audiodataoutput") || m.contains("ambisonic")
        if audioRelated {
            // The reference's stereo output is the least valuable part of the audio graph.
            if appliedReferenceAudioOutput && currentFallbacks.referenceAudio < 1 {
                currentFallbacks.referenceAudio = 1
                return true
            }
            if phase == "audio-input" {
                // Adding the microphone itself raised: no audio mode can help.
                if currentFallbacks.audio < 3 { currentFallbacks.audio = 3; return true }
                return false
            }
            // One step at a time: FOA → stereo → no multichannel mode → no microphone.
            if currentFallbacks.audio < 3 { currentFallbacks.audio += 1; return true }
            return false
        }
        if m.contains("stabiliz") && currentFallbacks.stabilization < 1 {
            currentFallbacks.stabilization = 1
            return true
        }
        if m.contains("moviefileoutput") && currentFallbacks.reference < 1 {
            currentFallbacks.reference = 1
            return true
        }
        switch phase {
        case "reference":
            if currentFallbacks.reference < 1 { currentFallbacks.reference = 1; return true }
        case "stabilization":
            if currentFallbacks.stabilization < 1 { currentFallbacks.stabilization = 1; return true }
        case "format", "pixel-format":
            if let id = pendingFormatID, !rejectedFormatIDs.contains(id) { rejectedFormatIDs.insert(id); return true }
        case "commit", "start":
            // Culprit not named: the in-session HEVC encoder and stabilization are the most demanding
            // parts of the graph; the microphone goes last, one audio step at a time.
            if currentFallbacks.reference < 1 { currentFallbacks.reference = 1; return true }
            if currentFallbacks.stabilization < 1 { currentFallbacks.stabilization = 1; return true }
            if currentFallbacks.referenceAudio < 1 && appliedReferenceAudioOutput { currentFallbacks.referenceAudio = 1; return true }
            if currentFallbacks.audio < 3 { currentFallbacks.audio += 1; return true }
        default:
            break
        }
        return false
    }

    /// The NSGenericException AVFoundation raises when startRunning/stopRunning is called while a
    /// configuration block is still open: a symptom of the session's state, not of the graph.
    static func isConfigurationStateException(_ message: String) -> Bool {
        message.contains("beginConfiguration") && message.contains("commitConfiguration")
    }

    static func firstLine(_ message: String) -> String {
        let line = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
        return line.count > 220 ? String(line.prefix(220)) + "…" : line
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

    /// Full teardown before a rebuild (retry, safe-mode reset, media services reset, recovery
    /// after a recording error): a fresh session carries no state from the failed one.
    private func tearDownSessionOnQueue() {
        replaceSession(reason: "rebuild", configurationOpen: inConfiguration)
    }

    /// Retires the current session and installs a fresh one with fresh outputs (an output can
    /// belong to one session only, and the old session may still own them). Session queue only.
    ///
    /// The old session is emptied and its configuration block closed first, so it can be stopped
    /// and releases the camera and microphone before the new one starts: an empty graph always
    /// validates, which lets the pending outermost commit go through. `configurationOpen` says
    /// whether a block is still open (then no new beginConfiguration is issued).
    private func replaceSession(reason: String, configurationOpen: Bool) {
        let old = session
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        referenceAudioOutput?.setSampleBufferDelegate(nil, queue: nil)
        if let ex = LCCatchObjCException({
            if !configurationOpen { old.beginConfiguration() }
            for o in old.outputs { old.removeOutput(o) }
            for i in old.inputs { old.removeInput(i) }
            old.commitConfiguration()
        }) {
            diagnostics.log("capture", "Emptying the old session raised: \(Self.firstLine(ex))")
        }
        if old.isRunning {
            if let ex = LCCatchObjCException({ old.stopRunning() }) {
                diagnostics.log("capture", "Stopping the old session raised: \(Self.firstLine(ex))")
            }
        }
        sessionBox.value = AVCaptureSession()
        videoOutput = AVCaptureVideoDataOutput()
        audioOutput = AVCaptureAudioDataOutput()
        referenceAudioOutput = nil
        videoInput = nil
        audioInput = nil
        inConfiguration = false
        appliedFOA = false
        appliedReferenceAudioOutput = false
        reference.detach()
        sessionReplacements += 1
        diagnostics.log("capture", "Capture session replaced (\(reason)); replacement #\(sessionReplacements)")
        DispatchQueue.main.async { self.sessionVersion += 1 }
    }

    // MARK: Runtime errors and interruptions (session queue)

    private func handleRuntimeError(_ error: NSError?, generation: Int) {
        let detail = DiagnosticsLog.describe(error)
        let sinceCommit = CACurrentMediaTime() - lastCommitTime
        if generation != configGeneration {
            // Posted for a configuration that has since been replaced (rapid setting changes, or a
            // second error for a fault the ladder already handled).
            diagnostics.log("session", "Runtime error from an earlier configuration ignored: \(detail)")
            return
        }
        runtimeErrorsSinceCommit += 1
        lastConfigureSucceeded = false
        diagnostics.log("session", "Runtime error: \(detail) · running=\(session.isRunning) · \(String(format: "%.1f", sinceCommit)) s after commit · fallbacks[\(currentFallbacks.summary)]")
        if isRecordingNow {
            // Never tear the graph down under a running recording; the user stops it and the next
            // ladder step is applied then. The configuration was committed and ran, so a later
            // crash is not a setup crash.
            UserDefaults.standard.set(false, forKey: Self.inFlightKey)
            needsRebuildAfterRecording = true
            publishError("Camera session error while recording: \(DiagnosticsLog.shortLabel(error)). Stop the recording; the session will be rebuilt with a less demanding configuration.")
            return
        }
        // -11819 AVErrorMediaServicesWereReset: the whole capture graph is gone; rebuild it. A reset
        // right after a configuration, for the second time, is treated like any other recurring error.
        if error?.domain == AVFoundationErrorDomain && error?.code == -11819 {
            let near = sinceCommit < 10
            if near { mediaResetsNearCommit += 1 }
            tearDownSessionOnQueue()
            if near && mediaResetsNearCommit >= 2 {
                if applyNextLadderStep(error: error) {
                    configureOnQueue(reason: "recovery after repeated media services resets")
                } else {
                    finishFailed("The camera's media services keep resetting with this configuration. Tap Retry, or change resolution / frame rate / stabilization.")
                }
                return
            }
            publishError("Media services were reset; rebuilding the camera session")
            configureOnQueue(reason: "media services reset")
            return
        }
        let now = CACurrentMediaTime()
        let recent = sinceCommit < 10 || now - lateRestartAt < 10
        if !recent {
            // A late, isolated error: restart once before blaming the configuration.
            lateRestartAt = now
            publishError("Camera session error: \(DiagnosticsLog.shortLabel(error)); restarting the session")
            if !session.isRunning {
                if let ex = LCCatchObjCException({ self.session.startRunning() }) {
                    diagnostics.log("session", "startRunning raised \(ex)")
                }
            }
            return
        }
        if applyNextLadderStep(error: error) {
            configureOnQueue(reason: "recovery")
            return
        }
        finishFailed("Camera session error: \(DiagnosticsLog.shortLabel(error)). Tap Retry, or change resolution / frame rate / stabilization.")
    }

    private func resetLadder() {
        ladder.removeAll()
        ladderIndex = -1
        mediaResetsNearCommit = 0
        lateRestartAt = -1000
    }

    /// Builds the ladder from what the failing configuration actually uses: each suspect is first
    /// removed on its own (so the culprit is found without giving up the others), then in pairs,
    /// then everything, and finally the microphone input.
    private func buildLadder() {
        let base = currentFallbacks
        ladderBase = base
        var singles: [(Fallbacks, String)] = []
        if appliedReferenceAudioOutput {
            var f = base; f.referenceAudio = 1
            singles.append((f, "second (stereo) audio output for the HEVC reference removed"))
        }
        if appliedMovieOutput {
            var f = base; f.reference = 1
            singles.append((f, "MovieFileOutput removed; HEVC reference now encoded by AVAssetWriter from the same frames"))
        }
        if appliedStabilization {
            var f = base; f.stabilization = 1
            singles.append((f, "video stabilization disabled for this format on this device"))
        }
        if appliedMultichannel {
            // Spatial capture steps down to stereo first; stereo steps down to no multichannel mode.
            var f = base
            if appliedFOA {
                f.audio = max(f.audio, 1); f.referenceAudio = 1
                singles.append((f, "spatial audio replaced by stereo"))
            } else {
                f.audio = max(f.audio, 2)
                singles.append((f, "stereo microphone mode disabled"))
            }
        }
        var steps = singles
        if singles.count >= 2 {
            for i in 0..<singles.count {
                for j in (i + 1)..<singles.count {
                    var f = singles[i].0
                    let g = singles[j].0
                    f.reference = max(f.reference, g.reference)
                    f.stabilization = max(f.stabilization, g.stabilization)
                    f.audio = max(f.audio, g.audio)
                    f.referenceAudio = max(f.referenceAudio, g.referenceAudio)
                    steps.append((f, singles[i].1 + " and " + singles[j].1))
                }
            }
        }
        if appliedMovieOutput || appliedStabilization || appliedMultichannel {
            var f = base
            if appliedMovieOutput { f.reference = 1 }
            if appliedStabilization { f.stabilization = 1 }
            if appliedMultichannel { f.audio = max(f.audio, 2) }
            f.referenceAudio = 1
            if !steps.contains(where: { $0.0 == f }) {
                steps.append((f, "MovieFileOutput, stabilization and multichannel audio all disabled"))
            }
        }
        if audioInput != nil {
            var f = base
            if appliedMovieOutput { f.reference = 1 }
            if appliedStabilization { f.stabilization = 1 }
            f.audio = 3
            f.referenceAudio = 1
            steps.append((f, "microphone input disabled"))
        }
        ladder = steps
        ladderIndex = -1
    }

    /// Applies the next ladder step; false when the ladder is exhausted.
    private func applyNextLadderStep(error: NSError?) -> Bool {
        if ladder.isEmpty || ladderIndex < 0 { buildLadder() }
        ladderIndex += 1
        guard ladderIndex < ladder.count else { return false }
        let step = ladder[ladderIndex]
        workingFallbacks.removeValue(forKey: Self.signature(currentSettings))
        currentFallbacks = step.0
        let message = "\(DiagnosticsLog.shortLabel(error)) → \(step.1) (step \(ladderIndex + 1) of \(ladder.count))"
        diagnostics.log("recovery", message)
        publishError(message)
        return true
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
            // Only the control fields change here; format fields go through configure(settings:).
            var merged = self.currentSettings
            merged.exposure = settings.exposure
            merged.shutterSeconds = settings.shutterSeconds
            merged.iso = settings.iso
            merged.whiteBalance = settings.whiteBalance
            merged.temperature = settings.temperature
            merged.tint = settings.tint
            merged.focus = settings.focus
            merged.lensPosition = settings.lensPosition
            self.currentSettings = merged
            self.applyDeviceControlsOnQueue(settings: merged)
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
        // An exception unwinding through Swift would skip a `defer`; unlock explicitly instead.
        let ex = LCCatchObjCException { self.applyControlsLocked(device, settings: settings) }
        device.unlockForConfiguration()
        if let ex = ex { diagnostics.log("controls", "device control raised \(ex)") }
    }

    /// Called with the device locked for configuration.
    private func applyControlsLocked(_ device: AVCaptureDevice, settings: CaptureSettings) {
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
            if self.session.isRunning && !self.isRecordingNow {
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
            UserDefaults.standard.set(false, forKey: Self.inFlightKey)   // a crash from here on is not a setup crash
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
            guard isRecordingNow, !stopInProgress else { DispatchQueue.main.async { completion(nil) }; return }
            stopInProgress = true
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
                        self.stopInProgress = false
                        AudioSessionState.shared.captureActive = false
                        let pending = self.pendingSettings
                        self.pendingSettings = nil
                        if self.needsRebuildAfterRecording {
                            self.needsRebuildAfterRecording = false
                            if let s = pending, Self.signature(s) != Self.signature(self.currentSettings) {
                                // The user asked for a different format meanwhile: start from it.
                                self.currentSettings = s
                                self.currentFallbacks = self.workingFallbacks[Self.signature(s)] ?? Fallbacks()
                                self.rejectedFormatIDs.removeAll()
                                self.resetLadder()
                            } else {
                                if let s = pending { self.currentSettings = s }
                                // The error happened with this graph: do not rebuild it unchanged.
                                if !self.applyNextLadderStep(error: nil) {
                                    self.diagnostics.log("recovery", "Ladder exhausted after a recording error; rebuilding as is")
                                }
                            }
                            self.tearDownSessionOnQueue()
                            self.configureOnQueue(reason: "rebuild after recording error")
                        } else if let s = pending {
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

// The manager is the delegate of exactly one video and one audio data output (the lossless ones);
// the reference's stereo output has its own delegate (ReferenceAudioTap). Dispatch is by type:
// the output references are replaced on the session queue while these callbacks run on others.
extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            let now = CACurrentMediaTime()
            previewRate.add(1, at: now)
            if now - lastPreviewPublish > 0.5 {
                lastPreviewPublish = now
                let fps = previewRate.rate(at: now)
                DispatchQueue.main.async { self.previewFps = fps }
            }
            pipeline.ingestVideo(sampleBuffer)
        } else if output is AVCaptureAudioDataOutput {
            reference.noteAudioFormat(sampleBuffer, dedicated: false)
            pipeline.ingestAudio(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            var reason = "unknown"
            if let att = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) {
                reason = String(describing: att)
            }
            pipeline.noteSourceDrop(reason: reason)
        }
    }
}

/// Delegate of the stereo audio data output that exists only for the HEVC reference while the
/// lossless output captures first-order ambisonics.
final class ReferenceAudioTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private weak var reference: ReferenceRecorder?

    init(reference: ReferenceRecorder) {
        self.reference = reference
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let reference = reference else { return }
        reference.noteAudioFormat(sampleBuffer, dedicated: true)
        reference.appendDedicatedAudio(sampleBuffer)
    }
}

/// Lock-protected reference to the current capture session (read from any thread, replaced on
/// the session queue).
final class SessionBox {
    private let lock = NSLock()
    private var current = AVCaptureSession()
    var value: AVCaptureSession {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// Lock-protected Int shared between notification threads and the session queue.
final class AtomicInt {
    private let lock = NSLock()
    private var v = 0
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// Lock-protected Bool shared between the main thread and the session queue.
final class AtomicFlag {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
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
