import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var capture: CaptureManager
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var stage2: Stage2Runner
    @Environment(\.dismiss) private var dismiss

    private var s: Binding<CaptureSettings> { $settings.settings }

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
            presetSection
            videoSection
            exposureSection
            whiteBalanceSection
            focusSection
            audioSection
            captureModeSection
            referenceSection
            jobsSection
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onChange(of: formatSignature) { _, _ in capture.configure(settings: settings.settings) }
        .onChange(of: controlSignature) { _, _ in capture.applyDeviceControls(settings: settings.settings) }
    }

    // MARK: Sections

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
                    Text(r.rawValue + (cat.isAvailable(resolution: r, fps: settings.settings.frameRate.rawValue, hdr: settings.settings.hdr) ? "" : " (n/a)")).tag(r)
                }
            }
            Picker("Frame rate", selection: s.frameRate) {
                ForEach(FrameRate.allCases) { f in
                    Text(f.label + (cat.isAvailable(resolution: settings.settings.resolution, fps: f.rawValue, hdr: settings.settings.hdr) ? "" : " (n/a)")).tag(f)
                }
            }
            Picker("Stabilization", selection: s.stabilization) {
                ForEach(Stabilization.allCases) { st in
                    Text(st.label + (cat.isStabilizationAvailable(st, resolution: settings.settings.resolution, fps: settings.settings.frameRate.rawValue, hdr: settings.settings.hdr) ? "" : " (n/a)")).tag(st)
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
                VStack(alignment: .leading) {
                    Text("Shutter 1/\(Int((1.0 / max(settings.settings.shutterSeconds, 1e-6)).rounded())) s").font(.caption)
                    Slider(value: Binding(get: { log2(1.0 / max(settings.settings.shutterSeconds, 1e-6)) },
                                          set: { settings.settings.shutterSeconds = 1.0 / pow(2, $0) }),
                           in: log2(1.0 / info.maxShutter)...log2(1.0 / info.minShutter))
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
                    LabeledContent("Benchmark pick") { Text(benchmark.recommended?.label ?? "not benchmarked yet (default LZ4 + shuffle)").font(.caption) }
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
            Text("Two-stage: frames are compressed losslessly with a fast codec during capture and transcoded to FFV1 v3 + FLAC in Matroska after you stop (no real-time constraint). Real-time FFV1 encodes the final format live; frames that cannot be kept up with are counted and reported, never dropped silently.")
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
        Section("Background jobs") {
            if stage2.jobs.isEmpty { Text("No stage-2 / verification jobs").foregroundStyle(.secondary) }
            ForEach(stage2.jobs) { j in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(j.baseName).font(.caption).lineLimit(1)
                        Spacer()
                        Text(j.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !j.finished { ProgressView(value: j.progress) }
                    Text(j.phase).font(.caption2).foregroundStyle(j.error == nil ? .secondary : .red)
                }
            }
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
            LabeledContent("Device", value: UIDevice.current.model + " · iOS " + UIDevice.current.systemVersion)
            LabeledContent("Cores", value: "\(ProcessInfo.processInfo.activeProcessorCount) active")
            LabeledContent("Memory available", value: availableMemoryBytes().byteCountString)
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
