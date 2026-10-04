import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var capture: CaptureManager
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var stage2: Stage2Runner
    @Environment(\.dismiss) private var dismiss

    private var s: Binding<CaptureSettings> { $settings.settings }
    private var isRecording: Bool { capture.state == .recording || capture.state == .finishing }

    /// Changing these requires a session reconfiguration.
    private var formatSignature: String {
        let v = settings.settings
        return "\(v.resolution.rawValue)|\(v.frameRate.rawValue)|\(v.stabilization.rawValue)|\(v.hdr)|\(v.audio.rawValue)|\(v.referenceRecorder.rawValue)"
    }
    /// These apply live.
    private var controlSignature: String {
        let v = settings.settings
        return "\(v.exposure.rawValue)|\(v.shutterSeconds)|\(v.iso)|\(v.whiteBalance.rawValue)|\(v.temperature)|\(v.tint)|\(v.focus.rawValue)|\(v.lensPosition)"
    }

    var body: some View {
        Form {
            if isRecording {
                Section {
                    Label("Recording in progress: format, audio and reference changes are applied when it stops.", systemImage: "record.circle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            if capture.safeModeLevel > 0 || !capture.fallbacks.isClean || capture.state == .failed {
                statusSection
            }
            presetSection
            videoSection
            exposureSection
            whiteBalanceSection
            focusSection
            audioSection
            captureModeSection
            referenceSection
            jobsSection
            diagnosticsSection
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onChange(of: formatSignature) { _, _ in capture.configure(settings: settings.settings) }
        .onChange(of: controlSignature) { _, _ in capture.applyDeviceControls(settings: settings.settings) }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            if capture.safeModeLevel > 0 {
                Label(CaptureManager.safeModeDescription(capture.safeModeLevel), systemImage: "shield.lefthalf.filled").font(.caption).foregroundStyle(.yellow)
                Button("Leave safe mode and retry the full configuration") { capture.resetSafeMode() }
            }
            if !capture.fallbacks.isClean {
                Label("Automatic fallbacks in effect: \(capture.fallbacks.summary)", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.orange)
                Text("The requested configuration produced an AVFoundation error on this device; the session was relaxed step by step until it ran. Details are in Diagnostics below.").font(.caption2).foregroundStyle(.secondary)
            }
            if capture.state == .failed {
                Button("Retry camera setup") { capture.retryConfiguration() }
            }
        } header: { Text("Session status") }
    }

    private var presetSection: some View {
        Section {
            HStack {
                ForEach([Preset.fancy, Preset.neutral]) { p in
                    Button {
                        var v = settings.settings
                        v.apply(preset: p)
                        if p == .neutral { capture.snapshotDeviceValues(into: &v) }
                        settings.settings = v
                    } label: {
                        VStack {
                            Text(p.rawValue).bold()
                            Text(p == .fancy ? "cinematic stab · HDR · all auto" : "stab off · SDR · exposure/WB/focus locked")
                                .font(.caption2).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(settings.settings.preset == p ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: { Text("Quick presets") } footer: { Text("Presets only set the toggles below; everything stays editable.") }
    }

    private var videoSection: some View {
        Section("Video") {
            let cat = capture.catalog
            Picker("Resolution", selection: s.resolution) {
                ForEach(Resolution.allCases) { r in
                    let ok = cat.isAvailable(resolution: r, fps: settings.settings.frameRate.rawValue, hdr: settings.settings.hdr)
                    Text(r.rawValue + (ok ? "" : " (not offered)")).foregroundStyle(ok ? Color.primary : Color.secondary).tag(r)
                }
            }
            Picker("Frame rate", selection: s.frameRate) {
                ForEach(FrameRate.allCases) { f in
                    let ok = cat.isAvailable(resolution: settings.settings.resolution, fps: f.rawValue, hdr: settings.settings.hdr)
                    Text(f.label + (ok ? "" : " (not offered)")).foregroundStyle(ok ? Color.primary : Color.secondary).tag(f)
                }
            }
            Picker("Stabilization", selection: s.stabilization) {
                ForEach(Stabilization.allCases) { st in
                    let ok = cat.isStabilizationAvailable(st, resolution: settings.settings.resolution, fps: settings.settings.frameRate.rawValue, hdr: settings.settings.hdr)
                    Text(st.label + (ok ? "" : " (not offered)")).foregroundStyle(ok ? Color.primary : Color.secondary).tag(st)
                }
            }
            Toggle("HDR video (10-bit HLG BT.2020)", isOn: s.hdr)
            if !settings.settings.hdr {
                Text("SDR captures the camera's 8-bit 4:2:0 format (yuv420p, BT.709) losslessly.").font(.caption).foregroundStyle(.secondary)
            }
            if !cat.isAvailable(resolution: settings.settings.resolution, fps: settings.settings.frameRate.rawValue, hdr: settings.settings.hdr) {
                Label("This combination is not offered by the camera; the closest supported format is used.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("Active format") { Text(capture.activeFormatSummary).font(.caption).multilineTextAlignment(.trailing) }
            NavigationLink("All camera formats") { FormatListView(catalog: cat) }
        }
    }

    private var exposureSection: some View {
        Section("Exposure") {
            Picker("Mode", selection: s.exposure) { ForEach(ExposureSetting.allCases) { Text($0.label).tag($0) } }
            if settings.settings.exposure == .locked {
                let info = capture.deviceInfo
                let minShutter = max(info.minShutter, 1.0 / 100_000)
                let maxShutter = max(info.maxShutter, minShutter * 2)
                VStack(alignment: .leading) {
                    Text("Shutter 1/\(Int((1.0 / max(settings.settings.shutterSeconds, 1e-6)).rounded())) s").font(.caption)
                    Slider(value: Binding(get: { log2(1.0 / max(settings.settings.shutterSeconds, 1e-6)) },
                                          set: { settings.settings.shutterSeconds = 1.0 / pow(2, $0) }),
                           in: log2(1.0 / maxShutter)...log2(1.0 / minShutter))
                }
                VStack(alignment: .leading) {
                    Text("ISO \(Int(settings.settings.iso))").font(.caption)
                    Slider(value: s.iso, in: info.minISO...max(info.maxISO, info.minISO + 1))
                }
                if !info.supportsCustomExposure { Text("Custom exposure unsupported by this camera").font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private var whiteBalanceSection: some View {
        Section("White balance") {
            Picker("Mode", selection: s.whiteBalance) { ForEach(WhiteBalanceSetting.allCases) { Text($0.label).tag($0) } }
            if settings.settings.whiteBalance == .locked {
                VStack(alignment: .leading) {
                    Text("Temperature \(Int(settings.settings.temperature)) K").font(.caption)
                    Slider(value: s.temperature, in: 2000...10000, step: 50)
                }
                VStack(alignment: .leading) {
                    Text("Tint \(Int(settings.settings.tint))").font(.caption)
                    Slider(value: s.tint, in: -150...150, step: 1)
                }
                Text("Gains are derived from temperature/tint and clamped to the device's maximum gain.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var focusSection: some View {
        Section("Focus") {
            Picker("Mode", selection: s.focus) { ForEach(FocusSetting.allCases) { Text($0.label).tag($0) } }
            if settings.settings.focus == .locked {
                VStack(alignment: .leading) {
                    Text(String(format: "Lens position %.3f (0 = near, 1 = far)", settings.settings.lensPosition)).font(.caption)
                    Slider(value: s.lensPosition, in: 0...1)
                }
            }
        }
    }

    private var audioSection: some View {
        Section {
            Picker("Audio", selection: s.audio) { ForEach(AudioSetting.allCases) { Text($0.label).tag($0) } }
            LabeledContent("Active") { Text(capture.audioModeDescription).font(.caption) }
            if !capture.microphoneAuthorized {
                Label("Microphone access is off for LosslessCam; recordings have no audio.", systemImage: "mic.slash").font(.caption).foregroundStyle(.orange)
                Button("Open iOS Settings for LosslessCam") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: { Text("Audio") } footer: {
            Text("Spatial = AVCaptureDeviceInput.multichannelAudioMode .firstOrderAmbisonics (4 channels, ACN/SN3D) stored as 4-channel FLAC; falls back to stereo when unsupported. Samples are stored exactly as delivered (24-bit FLAC, native sample rate, no resampling).")
        }
    }

    private var captureModeSection: some View {
        Section {
            Picker("Capture mode", selection: s.captureMode) { ForEach(CaptureMode.allCases) { Text($0.label).tag($0) } }
            if settings.settings.captureMode == .twoStage {
                Toggle("Stage-1 codec: auto (fastest sustaining from benchmark)", isOn: s.stage1Auto)
                if settings.settings.stage1Auto {
                    LabeledContent("Benchmark pick") { Text(benchmark.recommendation(bitDepth: settings.settings.hdr ? 10 : 8)?.label ?? "not benchmarked at this bit depth (default LZ4 + shuffle)").font(.caption) }
                } else {
                    Picker("Stage-1 codec", selection: s.stage1Codec) {
                        ForEach(Stage1CodecChoice.allCases) { c in
                            let ok = lc_stage1_codec_supported(c.lcCodec, settings.settings.hdr ? 2 : 1) != 0
                            Text(c.label + (ok ? "" : " (unsupported for \(settings.settings.hdr ? "10" : "8")-bit)")).tag(c)
                        }
                    }
                }
                NavigationLink("Benchmark stage-1 codecs on this device") { BenchmarkView() }
            }
            LabeledContent("Final FFV1") { Text("v3 · range coder · context 1 · \(settings.settings.ffv1Slices) slices · slice CRC · all intra").font(.caption).multilineTextAlignment(.trailing) }
            LabeledContent("Final FLAC") { Text("level \(settings.settings.flacCompressionLevel) · 24-bit").font(.caption) }
        } header: { Text("Lossless pipeline") } footer: {
            Text("Two-stage: frames are compressed losslessly with a fast codec during capture and transcoded to FFV1 v3 + FLAC in Matroska after you stop (no real-time constraint). Real-time FFV1 encodes the final format live. Frames the storage path cannot keep up with are dropped, counted and shown — never silently; the file keeps the real timeline with gaps where frames are missing.")
        }
    }

    private var referenceSection: some View {
        Section {
            Picker("HEVC reference", selection: s.referenceRecorder) { ForEach(ReferenceRecorderChoice.allCases) { Text($0.label).tag($0) } }
            LabeledContent("Active path") { Text(capture.referencePathDescription).font(.caption).multilineTextAlignment(.trailing) }
        } header: { Text("Reference recording") } footer: {
            Text("Apple's own HEVC Dolby Vision / HLG file recorded from the same session, stored next to the MKV with the same base name.")
        }
    }

    private var jobsSection: some View {
        Section {
            if stage2.jobs.isEmpty { Text("No stage-2 / verification jobs").foregroundStyle(.secondary) }
            ForEach(stage2.jobs) { j in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(j.baseName).font(.caption).lineLimit(1)
                        Spacer()
                        Text(j.kind.rawValue + (j.paused ? " · paused" : "")).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !j.finished { ProgressView(value: j.progress) }
                    Text(j.phase).font(.caption2).foregroundStyle(j.error == nil ? Color.secondary : Color.red)
                }
            }
        } header: { Text("Background jobs") } footer: {
            Text("Jobs pause automatically while a recording is in progress so the stage-1 workers keep every core.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            NavigationLink("Diagnostics log (\(DiagnosticsLog.shared.tail.count) lines)") { DiagnosticsView() }
            LabeledContent("Camera state", value: capture.state.rawValue)
            LabeledContent("Permissions", value: "camera \(capture.cameraAuthorized ? "granted" : "denied") · microphone \(capture.microphoneAuthorized ? "granted" : "denied")")
            LabeledContent("Fallbacks", value: capture.fallbacks.summary)
            LabeledContent("Safe mode", value: capture.safeModeLevel == 0 ? "off" : "level \(capture.safeModeLevel)")
        } header: { Text("Diagnostics") } footer: {
            Text("Session errors (with AVFoundation error codes), caught exceptions, recovery steps and recording summaries. Stored on this device only, in Documents/LosslessCam_diagnostics.log.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("LosslessCam", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            LabeledContent("FFmpeg", value: String(cString: lc_ffmpeg_version_string()))
            LabeledContent("License", value: String(cString: lc_ffmpeg_license()))
            NavigationLink("FFmpeg configuration") {
                ScrollView { Text(String(cString: lc_ffmpeg_configuration())).font(.system(.caption2, design: .monospaced)).padding() }
                    .navigationTitle("FFmpeg configure")
            }
            LabeledContent("Device", value: CaptureManager.deviceModelIdentifier() + " · iOS " + UIDevice.current.systemVersion)
            LabeledContent("Cores", value: "\(ProcessInfo.processInfo.activeProcessorCount) active")
            LabeledContent("Memory available", value: availableMemoryBytes().byteCountString)
        }
    }
}

/// Scrollable, copyable view of the diagnostics log.
struct DiagnosticsView: View {
    @ObservedObject private var log = DiagnosticsLog.shared
    @State private var copied = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if log.tail.isEmpty { Text("No entries yet").foregroundStyle(.secondary) }
                    ForEach(Array(log.tail.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .padding()
            }
            .onAppear { if let last = log.tail.indices.last { proxy.scrollTo(last, anchor: .bottom) } }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(copied ? "Copied" : "Copy all") {
                        UIPasteboard.general.string = log.text
                        copied = true
                    }
                    ShareLink(item: log.fileURL) { Label("Share log file", systemImage: "square.and.arrow.up") }
                    Button("Clear", role: .destructive) { log.clear() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

struct FormatListView: View {
    let catalog: FormatCatalog
    var body: some View {
        List(catalog.options) { o in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(o.width)×\(o.height) · \(o.fourCC) · ≤\(Int(o.maxFrameRate)) fps").font(.subheadline.monospacedDigit())
                Text("\(o.is10Bit ? "10-bit" : "8-bit") \(o.fullRange ? "full" : "video") range\(o.supportsHLG ? " · HLG" : "")\(o.binned ? " · binned" : "") · FOV \(Int(o.fieldOfView))° · stab: \(Stabilization.allCases.filter { o.stabilization[$0] == true }.map { $0.label }.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Camera formats")
    }
}
