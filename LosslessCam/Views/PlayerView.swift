import SwiftUI

struct PlayerView: View {
    let url: URL
    let title: String
    @StateObject private var holder = ModelHolder()
    @State private var showInfo = false
    @State private var scrub: Double = 0
    @State private var scrubbing = false

    final class ModelHolder: ObservableObject {
        @Published var model: PlayerModel?
        @Published var error: String?
        private var loading = false
        func load(url: URL) {
            guard model == nil, error == nil, !loading else { return }
            loading = true
            PlayerModel.load(url: url) { m in
                self.loading = false
                if let m = m { self.model = m } else { self.error = "Could not open \(url.lastPathComponent)" }
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let m = holder.model {
                PlayerBody(model: m, scrub: $scrub, scrubbing: $scrubbing, showInfo: $showInfo)
            } else if let e = holder.error {
                ContentUnavailableView(e, systemImage: "exclamationmark.triangle")
            } else {
                ProgressView("Opening…")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showInfo = true } label: { Image(systemName: "info.circle") } } }
        .onAppear { holder.load(url: url) }
        .onDisappear { holder.model?.pause() }
    }
}

private struct PlayerBody: View {
    @ObservedObject var model: PlayerModel
    @Binding var scrub: Double
    @Binding var scrubbing: Bool
    @Binding var showInfo: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                VideoRenderViewRepresentable(view: model.renderView)
                    .ignoresSafeArea(edges: .horizontal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("frame \(model.currentIndex) / \(model.frameCount - 1) · \(timestamp(model.currentPtsNs))").font(.caption.monospacedDigit().bold())
                    Text(String(format: "decode %.1f fps (%.1f ms) · %@ · %@", model.decodeFps, model.decodeMs, model.info.videoCodec.uppercased(), model.info.colorLabel)).font(.caption2.monospacedDigit())
                    Text("audio: \(model.audioChannelsLabel)" + (model.crcErrors > 0 ? " · \(model.crcErrors) CRC errors" : "")).font(.caption2)
                    if let p = model.inspector {
                        Text("px (\(p.x), \(p.y))  Y \(p.yCode)  Cb \(p.cbCode)  Cr \(p.crCode)  (\(p.bitDepth)-bit codes)").font(.caption.monospacedDigit().bold()).foregroundStyle(.yellow)
                    } else {
                        Text("two-finger hold: pixel inspector · pinch: zoom · drag: pan · tap: play/pause").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !model.statusText.isEmpty { Text(model.statusText).font(.caption2).foregroundStyle(.orange) }
                }
                .padding(8)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
            }
            controls
        }
        .sheet(isPresented: $showInfo) { MediaInfoSheet(info: model.info, url: model.url) }
        .onReceive(model.$currentIndex) { i in if !scrubbing { scrub = Double(i) } }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Slider(value: $scrub, in: 0...Double(max(model.frameCount - 1, 1)), step: 1) { editing in
                scrubbing = editing
                if !editing { model.seek(to: Int64(scrub)) }
            }
            .onChange(of: scrub) { _, v in if scrubbing { model.seek(to: Int64(v)) } }
            HStack(spacing: 18) {
                Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title) }
                Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }
                Spacer()
                Menu {
                    ForEach([0.1, 0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { s in
                        Button(String(format: "%g×", s)) { model.speed = s }
                    }
                } label: { Text(String(format: "%g×", model.speed)).monospacedDigit() }
                Menu {
                    ForEach(PlayerModel.PlaybackPacing.allCases) { p in Button(p.label) { model.pacing = p } }
                    Toggle("Audio", isOn: Binding(get: { model.audioEnabled }, set: { model.audioEnabled = $0 })).disabled(!model.hasAudio)
                    Toggle("Nearest-neighbour sampling", isOn: Binding(get: { model.params.nearest }, set: { model.params.nearest = $0 }))
                    Button("Reset zoom") { model.resetView() }
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

struct MediaInfoSheet: View {
    let info: MediaInfo
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                LabeledContent("File", value: url.lastPathComponent)
                LabeledContent("Container", value: info.container)
                LabeledContent("Video", value: "\(info.videoCodec) \(info.width)×\(info.height) \(info.bitDepth)-bit")
                LabeledContent("Frame rate", value: String(format: "%.3f fps", info.fps))
                LabeledContent("Frames", value: "\(info.frameCount)\(info.frameCountExact ? "" : " (estimated)")")
                LabeledContent("Duration", value: (Double(info.durationNs) / 1e9).durationString)
                LabeledContent("Colour", value: info.colorLabel)
                if info.ffv1Version > 0 { LabeledContent("FFV1 version", value: "\(info.ffv1Version)\(info.sliceCrc ? " · slice CRCs" : "")") }
                if let a = info.audioCodec {
                    LabeledContent("Audio", value: "\(a) \(info.channels) ch \(info.sampleRate) Hz\(info.ambisonic ? " · first-order ambisonics" : "")")
                }
            }
            .navigationTitle("Media info")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
