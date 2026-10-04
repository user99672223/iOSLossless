import SwiftUI

struct BenchmarkView: View {
    @EnvironmentObject var benchmark: BenchmarkRunner
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var capture: CaptureManager
    @State private var seconds: Double = 6
    @State private var use4K60 = true

    var body: some View {
        List {
            Section {
                Toggle("Benchmark at 4K60 10-bit (the default capture preset)", isOn: $use4K60)
                if !use4K60 {
                    Text("Using the active format: \(capture.activeFormatSummary)").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Duration per codec")
                    Slider(value: $seconds, in: 3...20, step: 1)
                    Text("\(Int(seconds)) s").monospacedDigit()
                }
                Button(benchmark.running ? "Running…" : "Run benchmark") { run() }
                    .disabled(benchmark.running)
                if benchmark.running {
                    ProgressView(value: benchmark.progress)
                    Text(benchmark.status).font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { benchmark.cancel() }
                }
            } footer: {
                Text("Each codec runs with a worker pool like the real pipeline: first compression only, then compression plus flash writes through the intermediate writer. The source is a recent camera frame when the camera is running, otherwise synthetic camera-like data. A codec “sustains” when its frames/s with I/O exceeds the target by 5%.")
            }

            if !benchmark.results.isEmpty {
                Section("Results (\(benchmark.results.first?.width ?? 0)×\(benchmark.results.first?.height ?? 0) \(benchmark.results.first?.bitDepth ?? 0)-bit, target \(benchmark.results.first?.targetFps ?? 0) fps, \(benchmark.results.first?.workers ?? 0) workers)") {
                    ForEach(benchmark.results) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(r.name).bold()
                                Spacer()
                                if !r.supported {
                                    Text("unsupported").font(.caption).foregroundStyle(.secondary)
                                } else if r.sustainsTarget {
                                    Label("sustains \(r.targetFps) fps", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                                } else {
                                    Label("too slow", systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
                                }
                            }
                            if r.supported {
                                Text(String(format: "%.1f fps codec-only · %.1f fps with flash writes", r.framesPerSecond, r.framesPerSecondWithIO)).font(.caption.monospacedDigit())
                                Text(String(format: "in %.0f MB/s · out %.0f MB/s · ratio %.2f×", r.inputMBps, r.outputMBps, r.compressionRatio)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            } else if let reason = r.reason {
                                Text(reason).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .opacity(r.supported ? 1 : 0.6)
                    }
                }
                Section("Recommendation") {
                    if let rec = benchmark.recommended {
                        let sustains = benchmark.results.first { $0.codec == rec.rawValue }?.sustainsTarget ?? false
                        Text(sustains ? "Fastest sustaining codec: \(rec.label)" : "No codec sustains the target on this device; fastest is \(rec.label). Expect dropped frames at this mode (they are counted and reported).")
                            .font(.subheadline)
                        Toggle("Use benchmark pick automatically", isOn: $settings.settings.stage1Auto)
                        if !settings.settings.stage1Auto {
                            Picker("Override", selection: $settings.settings.stage1Codec) {
                                ForEach(Stage1CodecChoice.allCases) { Text($0.label).tag($0) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Stage-1 benchmark")
    }

    private func run() {
        let fmt = capture.activeFormat
        let w = use4K60 ? 3840 : Int(fmt?.width ?? 3840)
        let h = use4K60 ? 2160 : Int(fmt?.height ?? 2160)
        let bps = use4K60 ? 2 : ((fmt?.is10Bit ?? true) ? 2 : 1)
        let fps = use4K60 ? 60 : settings.settings.frameRate.rawValue
        let sample = capture.pipeline.latestFrameForBenchmark
        benchmark.run(width: w, height: h, bytesPerSample: bps, targetFps: fps, seconds: seconds, sampleFrame: sample)
    }
}
