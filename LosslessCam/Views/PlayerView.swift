import SwiftUI

struct PlayerView: View {
    let url: URL
    let title: String
    @StateObject private var holder = ModelHolder()
    @State private var showInfo = false
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    @Environment(\.scenePhase) private var scenePhase

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
        // GPU work is not allowed from the background; stop decoding/rendering when the scene leaves the foreground.
        .onChange(of: scenePhase) { _, phase in if phase != .active { holder.model?.pause() } }
    }
}

private struct PlayerBody: View {
    @ObservedObject var model: PlayerModel
    @Binding var scrub: Double
    @Binding var scrubbing: Bool
    @Binding var showInfo: Bool
    @AppStorage("player.showOverlay") private var showOverlay = true
    @State private var overlayVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var resumeAfterScrub = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                VideoRenderViewRepresentable(view: model.renderView)
                    .ignoresSafeArea(edges: .horizontal)
                if showOverlay && overlayVisible {
                    overlay
                        .padding(8)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                        .transition(.opacity)
                }
            }
            controls
        }
        .sheet(isPresented: $showInfo) { MediaInfoSheet(info: model.info, url: model.url) }
        .onReceive(model.$currentIndex) { i in if !scrubbing { scrub = Double(i) } }
        .onReceive(model.$isPlaying) { playing in
            if playing { scheduleHide() } else { hideTask?.cancel(); withAnimation { overlayVisible = true } }
        }
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("frame \(model.currentIndex) / \(model.frameCount - 1) · \(timestamp(model.currentPtsNs)) / \(timestamp(model.timelineEndNs))")
                .font(.caption.monospacedDigit().bold())
            if model.gapAfterCurrentSeconds > 0 {
                Text(String(format: "gap: next frame in %.2f s (frames dropped during capture)", model.gapAfterCurrentSeconds))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.orange)
            }
            Text(String(format: "decode %.1f fps (%.1f ms) · %@ · %@", model.decodeFps, model.decodeMs, model.info.videoCodec.uppercased(), model.info.colorLabel)).font(.caption2.monospacedDigit())
            Text("audio: \(model.audioChannelsLabel)" + (model.crcErrors > 0 ? " · \(model.crcErrors) CRC errors" : "")).font(.caption2)
            if let p = model.inspector {
                Text("px (\(p.x), \(p.y))  Y \(p.yCode)  Cb \(p.cbCode)  Cr \(p.crCode)  (\(p.bitDepth)-bit codes)").font(.caption.monospacedDigit().bold()).foregroundStyle(.yellow)
            } else {
                Text("two-finger hold: pixel inspector · pinch: zoom · drag: pan · tap: play/pause").font(.caption2).foregroundStyle(.secondary)
            }
            if !model.statusText.isEmpty { Text(model.statusText).font(.caption2).foregroundStyle(.orange) }
        }
    }

    /// Hides the stats box a few seconds into playback so it does not sit on the picture
    /// (pausing — a tap on the video — brings it back).
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled && model.isPlaying { withAnimation { overlayVisible = false } }
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Slider(value: $scrub, in: 0...Double(max(model.frameCount - 1, 1)), step: 1) { editing in
                scrubbing = editing
                if editing {
                    resumeAfterScrub = model.isPlaying
                } else {
                    if resumeAfterScrub { model.play(from: Int64(scrub)) } else { model.seek(to: Int64(scrub)) }
                }
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
                    Toggle("Show info overlay", isOn: $showOverlay)
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
        let s = Double(max(ns, 0)) / 1e9
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
                Section {
                    LabeledContent("File", value: url.lastPathComponent)
                    LabeledContent("Container", value: info.container)
                    LabeledContent("Video", value: "\(info.videoCodec) \(info.width)×\(info.height) \(info.bitDepth)-bit")
                    LabeledContent("Frame rate", value: String(format: "%.3f fps (nominal)", info.fps))
                    LabeledContent("Frames", value: "\(info.frameCount)\(info.frameCountExact ? "" : " (estimated)")")
                    LabeledContent("Timeline", value: (Double(info.durationNs) / 1e9).durationString)
                    LabeledContent("Footage", value: String(format: "%.1f s (frames ÷ fps)", info.fps > 0 ? Double(info.frameCount) / info.fps : 0))
                    if info.gapCount > 0 {
                        LabeledContent("Gaps", value: "\(info.gapCount) · ≈\(info.missingFrames) frames missing (dropped during capture)")
                    } else {
                        LabeledContent("Gaps", value: "none")
                    }
                    LabeledContent("Colour", value: info.colorLabel)
                    if info.ffv1Version > 0 { LabeledContent("FFV1 version", value: "\(info.ffv1Version)\(info.sliceCrc ? " · slice CRCs" : "")") }
                    if let a = info.audioCodec {
                        LabeledContent("Audio", value: "\(a) \(info.channels) ch \(info.sampleRate) Hz\(info.ambisonic ? " · first-order ambisonics" : "")")
                    }
                } footer: {
                    Text("Timeline is the span between the first and the last frame by presentation timestamp; footage is the number of frames divided by the nominal frame rate. They differ when frames were dropped during capture. If a system performance panel (OS, GPU, CPU figures) appears over the video, it is iOS's Graphics HUD: Settings › Developer › Graphics HUD › off.")
                }
            }
            .navigationTitle("Media info")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
