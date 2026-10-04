import SwiftUI

struct ComparisonView: View {
    let urlA: URL
    let urlB: URL
    let titleA: String
    let titleB: String
    @StateObject private var holder = Holder()
    @State private var scrub: Double = 0
    @State private var scrubbing = false

    final class Holder: ObservableObject {
        @Published var model: ComparisonModel?
        @Published var error: String?
        func load(a: URL, b: URL) {
            guard model == nil, error == nil else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let m = ComparisonModel(urlA: a, urlB: b)
                DispatchQueue.main.async {
                    if let m = m { self.model = m } else { self.error = "Could not open one of the files" }
                }
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let m = holder.model {
                ComparisonBody(model: m, scrub: $scrub, scrubbing: $scrubbing, titleA: titleA, titleB: titleB)
            } else if let e = holder.error {
                ContentUnavailableView(e, systemImage: "exclamationmark.triangle")
            } else {
                ProgressView("Opening both files…")
            }
        }
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { holder.load(a: urlA, b: urlB) }
        .onDisappear { holder.model?.pause() }
    }
}

private struct ComparisonBody: View {
    @ObservedObject var model: ComparisonModel
    @Binding var scrub: Double
    @Binding var scrubbing: Bool
    let titleA: String
    let titleB: String

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                VideoRenderViewRepresentable(view: model.renderView)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A \(titleA) · frame \(model.currentIndex)   B \(titleB) · frame \(model.currentIndexB) (offset \(model.offsetFrames))").font(.caption2.monospacedDigit()).lineLimit(2)
                    Text(String(format: "%@ · decode %.1f pairs/s · %@", timestamp(model.currentPtsNs), model.decodeFps, model.infoA.colorLabel)).font(.caption2.monospacedDigit())
                    Text(metricsLine).font(.caption.monospacedDigit().bold())
                    if let p = model.inspector {
                        Text("\(p.source) px (\(p.x), \(p.y))  Y \(p.yCode)  Cb \(p.cbCode)  Cr \(p.crCode)").font(.caption.monospacedDigit().bold()).foregroundStyle(.yellow)
                    }
                    if model.mode == .abFlip { Text("showing \(model.params.showB ? "B" : "A") — tap to swap, hold to peek").font(.caption2).foregroundStyle(.secondary) }
                    if model.mode == .wipe { Text("drag to move the divider · two fingers to pan").font(.caption2).foregroundStyle(.secondary) }
                    if !model.statusText.isEmpty { Text(model.statusText).font(.caption2).foregroundStyle(.orange) }
                }
                .padding(8)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
            }
            controls
        }
        .onReceive(model.$currentIndex) { i in if !scrubbing { scrub = Double(i) } }
    }

    private var metricsLine: String {
        let m = model.metrics
        let cur = m.identical ? "identical" : String(format: "PSNR %.2f dB · SSIM %.4f", m.psnr, m.ssim)
        return "luma \(cur) · avg over \(model.framesMeasured): " + String(format: "%.2f dB / %.4f", model.averagePSNR, model.averageSSIM)
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Picker("Mode", selection: $model.mode) {
                ForEach([CompareMode.sideBySide, .abFlip, .wipe, .difference]) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            if model.mode == .difference {
                HStack {
                    Text("gain").font(.caption)
                    Slider(value: Binding(get: { Double(model.params.gain) }, set: { model.params.gain = Float($0) }), in: 1...64)
                    Text(String(format: "%.0f×", model.params.gain)).font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 12)
            }
            Slider(value: $scrub, in: 0...Double(max(model.frameCount - 1, 1)), step: 1) { editing in
                scrubbing = editing
                if !editing { model.seek(to: Int64(scrub)) }
            }
            .onChange(of: scrub) { _, v in if scrubbing { model.seek(to: Int64(v)) } }
            .padding(.horizontal, 12)
            HStack(spacing: 16) {
                Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title) }
                Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }
                Spacer()
                Stepper("B offset \(model.offsetFrames)", value: $model.offsetFrames, in: -600...600).font(.caption)
                Button(model.aligning ? "…" : "Auto-align") { model.autoAlign() }.font(.caption).disabled(model.aligning)
                Menu {
                    Button("Reset averages") { model.resetAverages() }
                    Button("Reset zoom") { model.resetView() }
                    Toggle("Nearest-neighbour sampling", isOn: Binding(get: { model.params.nearest }, set: { model.params.nearest = $0 }))
                    ForEach([0.25, 0.5, 1.0, 2.0], id: \.self) { s in Button(String(format: "Speed %g×", s)) { model.speed = s } }
                } label: { Image(systemName: "gearshape") }
            }
            .font(.title3)
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.black)
    }

    private func timestamp(_ ns: Int64) -> String {
        let s = Double(ns) / 1e9
        let m = Int(s) / 60
        return String(format: "%02d:%06.3f", m, s - Double(m * 60))
    }
}
