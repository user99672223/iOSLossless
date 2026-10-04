import SwiftUI
import AVFoundation
import Combine

/// Live preview layer that follows the device orientation via the rotation coordinator.
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?

    /// Binds the layer to `session`. The capture manager replaces its session after a failed
    /// configuration; the new session gets a new preview connection, so the rotation angle is
    /// re-applied on every call (the coordinator follows the device, which does not change).
    func attach(session: AVCaptureSession) {
        if previewLayer.session !== session { previewLayer.session = session }
        previewLayer.videoGravity = .resizeAspect
        if coordinator == nil, let input = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }) {
            let c = AVCaptureDevice.RotationCoordinator(device: input.device, previewLayer: previewLayer)
            coordinator = c
            observation = c.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotation() }
            }
        }
        applyRotation()
    }

    private func applyRotation() {
        guard let c = coordinator, let conn = previewLayer.connection else { return }
        let angle = c.videoRotationAngleForHorizonLevelPreview
        if conn.videoRotationAngle != angle && conn.isVideoRotationAngleSupported(angle) {
            conn.videoRotationAngle = angle
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Changes when the capture manager replaces its session (forces `updateUIView`).
    let sessionVersion: Int
    let inputsVersion: Int
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.backgroundColor = .black
        v.attach(session: session)
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.attach(session: session)
    }
}

/// Dismissible message line over the preview.
struct MessageBanner: View {
    let text: String
    let color: Color
    let icon: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            if let d = onDismiss {
                Button(action: d) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(8)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CaptureView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var capture: CaptureManager
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var stage2: Stage2Runner
    @State private var showSettings = false
    @State private var showLastRecording = false
    @State private var stopRequested = false

    private var isRecording: Bool { capture.state == .recording || capture.state == .finishing }

    var body: some View {
        ZStack {
            CameraPreview(session: capture.session, sessionVersion: capture.sessionVersion, inputsVersion: capture.session.inputs.count)
                .ignoresSafeArea()
            if capture.state == .unauthorized {
                Color.black.ignoresSafeArea()
                ContentUnavailableView {
                    Label("Camera access is off", systemImage: "camera.badge.ellipsis")
                } description: {
                    Text("LosslessCam needs the camera (and the microphone for audio). Turn access on in iOS Settings; iOS restarts the app when you change it.")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            VStack(spacing: 8) {
                topBar
                if let adv = capture.advisory {
                    MessageBanner(text: adv, color: .yellow, icon: "exclamationmark.triangle.fill")
                }
                if let e = capture.lastError {
                    MessageBanner(text: e, color: .orange, icon: "exclamationmark.circle.fill") { capture.lastError = nil }
                }
                if capture.state == .failed {
                    Button { capture.retryConfiguration() } label: {
                        Label("Retry camera setup", systemImage: "arrow.clockwise").font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                if isRecording { DropWarning(pipeline: capture.pipeline) }
                TelemetryOverlay(pipeline: capture.pipeline, visible: isRecording)
                if !isRecording { LastRecordingBanner(pipeline: capture.pipeline) }
                if let job = stage2.current {
                    JobBanner(job: job)
                }
                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .onAppear { capture.startRunning() }
        .onDisappear { if !isRecording { capture.stopRunning() } }
        .onReceive(capture.pipeline.$fatalFailure) { e in
            // The pipeline cannot continue (storage full, writer failure): stop cleanly instead of recording nothing.
            if e != nil, capture.state == .recording, !stopRequested {
                stopRequested = true
                capture.stopRecording { _ in library.refresh(); stopRequested = false }
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .sheet(isPresented: $showLastRecording) {
            if let r = capture.lastRecording { NavigationStack { RecordingDetailView(recordingID: r.baseName) } }
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(capture.activeFormatSummary).font(.caption2).lineLimit(2)
                Spacer()
                Text(stateLabel).font(.caption.bold()).foregroundStyle(isRecording ? Color.red : Color.secondary)
            }
            HStack {
                Text("Audio: \(capture.audioModeDescription)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "preview %.0f fps", capture.previewFps)).font(.caption2).foregroundStyle(.secondary)
            }
            Text("Reference: \(capture.referencePathDescription)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text("Lossless path: \(settings.settings.captureMode == .twoStage ? "two-stage · stage 1 \(effectiveStage1.label)" : "real-time FFV1")").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var stateLabel: String {
        switch capture.state {
        case .idle: return "Idle"
        case .unauthorized: return "Camera access denied"
        case .configuring: return "Configuring…"
        case .running: return "Ready"
        case .recording: return "● REC"
        case .finishing: return "Finishing…"
        case .interrupted: return "Interrupted"
        case .failed: return "Failed"
        }
    }

    /// Stage-1 codec for the next recording: the benchmark pick measured at this bit depth (or the
    /// manual choice), falling back to LZ4 + shuffle when the codec cannot take this bit depth.
    private var effectiveStage1: Stage1CodecChoice {
        let tenBit = capture.activeFormat?.is10Bit ?? settings.settings.hdr
        let choice = settings.settings.stage1Auto ? (benchmark.recommendation(bitDepth: tenBit ? 10 : 8) ?? .lz4Shuffle) : settings.settings.stage1Codec
        return lc_stage1_codec_supported(choice.lcCodec, tenBit ? 2 : 1) != 0 ? choice : .lz4Shuffle
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                presetButton(.fancy)
                presetButton(.neutral)
                Spacer()
                quickToggle(settings.settings.resolution.shortName) {
                    settings.settings.resolution = settings.settings.resolution == .p2160 ? .p1080 : .p2160
                    settings.settings.preset = .custom
                    capture.configure(settings: settings.settings)
                }
                quickToggle("\(settings.settings.frameRate.rawValue)") {
                    let all = FrameRate.allCases
                    let i = all.firstIndex(of: settings.settings.frameRate) ?? 0
                    settings.settings.frameRate = all[(i + 1) % all.count]
                    settings.settings.preset = .custom
                    capture.configure(settings: settings.settings)
                }
                quickToggle(settings.settings.hdr ? "HLG" : "SDR") {
                    settings.settings.hdr.toggle()
                    settings.settings.preset = .custom
                    capture.configure(settings: settings.settings)
                }
            }
            .disabled(isRecording)
            HStack {
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.title2).padding(12)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .disabled(isRecording)
                Spacer()
                Button(action: toggleRecording) {
                    ZStack {
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
                        if isRecording {
                            RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 34, height: 34)
                        } else {
                            Circle().fill(.red).frame(width: 62, height: 62)
                        }
                    }
                }
                .disabled(capture.state == .finishing || capture.state == .unauthorized || capture.state == .failed || capture.state == .configuring)
                Spacer()
                Button { showLastRecording = true } label: {
                    Image(systemName: "film").font(.title2).padding(12)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .disabled(capture.lastRecording == nil)
            }
        }
    }

    private func presetButton(_ p: Preset) -> some View {
        Button {
            var s = settings.settings
            s.apply(preset: p)
            if p == .neutral { capture.snapshotDeviceValues(into: &s) }
            settings.settings = s
            capture.configure(settings: s)
        } label: {
            Text(p.rawValue)
                .font(.caption.bold())
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(settings.settings.preset == p ? Color.accentColor : Color.black.opacity(0.5), in: Capsule())
        }
    }

    private func quickToggle(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.bold()).monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.black.opacity(0.5), in: Capsule())
        }
    }

    private func toggleRecording() {
        if isRecording {
            capture.stopRecording { _ in library.refresh() }
        } else {
            capture.pipeline.clearMessage()
            capture.startRecording(settings: settings.settings, stage1Codec: effectiveStage1)
        }
    }
}

/// End-of-take summary (frames kept, drops, failures); dismissible.
struct LastRecordingBanner: View {
    @ObservedObject var pipeline: RecordingPipeline
    var body: some View {
        if let m = pipeline.lastMessage {
            let bad = m.lowercased().contains("dropped") || m.lowercased().contains("stopped") || m.lowercased().contains("no frames")
            MessageBanner(text: m, color: bad ? Color.orange : Color.green, icon: "film") { pipeline.clearMessage() }
        }
    }
}

struct JobBanner: View {
    let job: Stage2Runner.Job
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.kind == .transcode ? "Stage 2: FFV1 + FLAC" : "Verification").font(.caption.bold())
                Spacer()
                Text("\(Int(job.progress * 100))%").font(.caption).monospacedDigit()
            }
            ProgressView(value: job.progress)
            Text(job.paused ? "Paused while recording · " + job.phase : job.phase).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Impossible-to-miss warning while frames are being dropped.
struct DropWarning: View {
    @ObservedObject var pipeline: RecordingPipeline

    var body: some View {
        let t = pipeline.telemetry
        if let f = t.failure {
            Label(f, systemImage: "xmark.octagon.fill")
                .font(.caption.bold())
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        } else if t.droppedFrames > 0 {
            VStack(spacing: 2) {
                Text(t.recentDropFraction > 0.02
                     ? String(format: "DROPPING FRAMES — keeping %.0f%% right now", (1 - t.recentDropFraction) * 100)
                     : String(format: "%lld frames dropped so far (%.0f%% kept)", t.droppedFrames, t.keptFraction * 100))
                    .font(.headline.monospacedDigit())
                Text(String(format: "pipeline %.1f fps of %.1f delivered · timeline %.1f s · footage %.1f s", t.achievedFps, t.ingestFps, t.timelineSeconds, t.contentSeconds))
                    .font(.caption2.monospacedDigit())
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background((t.recentDropFraction > 0.02 ? Color.red : Color.orange).opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct TelemetryOverlay: View {
    @ObservedObject var pipeline: RecordingPipeline
    let visible: Bool

    var body: some View {
        if visible {
            let t = pipeline.telemetry
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(t.elapsedSeconds.durationString).font(.title3.monospacedDigit().bold())
                    Spacer()
                    Text(String(format: "%.1f fps written · %.1f in", t.achievedFps, t.ingestFps)).font(.caption.monospacedDigit())
                }
                row("Frames", "\(t.framesWritten) written · \(t.framesIngested) delivered" + (t.droppedFrames + t.sourceDroppedFrames > 0 ? " · \(t.droppedFrames) dropped (pipeline) · \(t.sourceDroppedFrames) dropped (source)" : " · none dropped"),
                    t.droppedFrames + t.sourceDroppedFrames > 0 ? Color.red : Color.green)
                HStack {
                    Text("Buffer").font(.caption2)
                    ProgressView(value: min(t.bufferFill, 1)).tint(t.bufferFill > 0.8 ? Color.red : Color.green)
                    Text("\(Int(t.bufferFill * 100))% (\(t.bufferCount)/\(t.bufferCapacity))").font(.caption2.monospacedDigit())
                }
                row("Write", String(format: "%.0f MB/s · %@ · ratio %.2f×", t.writeMBps, t.bytesWritten.byteCountString, t.compressionRatio))
                row("Thermal", t.thermalLabel, t.thermalState.rawValue >= 2 ? Color.orange : Color.primary)
                row("Free", "\(t.freeStorageBytes.byteCountString) · ~\(t.estimatedRemainingSeconds.durationString) left at this rate")
                row("Audio", "\(t.audioFormat) · \(t.audioFrames) frames" + (t.audioInexactSamples > 0 ? " · \(t.audioInexactSamples) inexact" : ""))
                row("Stage 1", "\(t.stage1Codec) · \(t.workerCount) workers · mem \(t.availableMemoryBytes.byteCountString)" + (t.memoryWarnings > 0 ? " · \(t.memoryWarnings) mem warnings" : ""))
                ForEach(t.notes.suffix(2), id: \.self) { n in Text(n).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
            }
            .padding(8)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func row(_ k: String, _ v: String, _ color: Color = .primary) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(v).font(.caption2.monospacedDigit()).foregroundStyle(color)
            Spacer()
        }
    }
}
