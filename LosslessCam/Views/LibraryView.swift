import SwiftUI

struct VerificationBadge: View {
    let state: Recording.VerificationState
    let stage2: Recording.Stage2State
    /// Live job for this recording (progress shown instead of the persisted value).
    var job: Stage2Runner.Job? = nil
    var body: some View {
        badge(label.0, label.1, label.2)
    }
    private func badge(_ text: String, _ color: Color, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
    private var label: (String, Color, String) {
        if let j = job, !j.finished {
            let p = Int(j.progress * 100)
            if j.kind == .transcode { return (j.paused ? "Stage 2 paused \(p)%" : "Stage 2 \(p)%", .blue, "gearshape.2") }
            return (j.paused ? "Verifying (paused)" : "Verifying \(p)%", .blue, "hourglass")
        }
        switch stage2.status {
        case .pending, .running: return ("Stage 2 \(Int(stage2.progress * 100))%", .blue, "gearshape.2")
        case .failed: return ("Stage 2 failed", .red, "xmark.octagon")
        case .cancelled: return ("Stage 2 cancelled", .orange, "stop.circle")
        default: break
        }
        switch state.status {
        case .pass: return ("PASS", .green, "checkmark.seal.fill")
        case .fail: return ("FAIL", .red, "xmark.seal.fill")
        case .running: return ("Verifying…", .blue, "hourglass")
        case .error: return ("Unverified", .orange, "questionmark.circle")
        case .cancelled: return ("Cancelled", .orange, "stop.circle")
        case .notRun: return ("Not verified", .gray, "circle.dashed")
        }
    }
}

struct ThumbnailView: View {
    @EnvironmentObject var library: LibraryStore
    let recording: Recording
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2))
            if let img = image {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear { if image == nil, recording.files.mkv != nil { library.thumbnail(for: recording) { image = $0 } } }
        .onChange(of: recording.files.mkv) { _, _ in library.thumbnail(for: recording) { image = $0 } }
    }
}

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var stage2: Stage2Runner
    @State private var compareA: Recording?
    @State private var showCompareAny = false

    var body: some View {
        NavigationStack {
            List {
                if library.recordings.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "film.stack", description: Text("Recordings appear here and in the Files app under LosslessCam."))
                }
                ForEach(library.recordings) { r in
                    NavigationLink(value: r.baseName) { RecordingRow(recording: r) }
                }
                .onDelete { idx in idx.map { library.recordings[$0] }.forEach { library.delete($0) } }
            }
            .navigationDestination(for: String.self) { id in RecordingDetailView(recordingID: id) }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(library.totalBytes.byteCountString + " · free " + freeStorageBytes().byteCountString).font(.caption).foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh") { library.refresh() }
                        Button("Compare any two…") { showCompareAny = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .refreshable { library.refresh() }
            .sheet(isPresented: $showCompareAny) { CompareAnyPicker() }
        }
    }
}

struct RecordingRow: View {
    @EnvironmentObject var stage2: Stage2Runner
    let recording: Recording
    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(recording: recording)
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.baseName).font(.caption).lineLimit(1)
                Text("\(recording.resolutionLabel) · \(recording.fps) fps · \(recording.bitDepth)-bit \(recording.hdr ? "HLG" : "SDR") · \(recording.timelineLabel) · \(recording.fileSizeBytes.byteCountString)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(recording.files.mkv != nil ? "FFV1" + (recording.audio != nil ? "+FLAC" : "") : (recording.files.intermediate != nil ? "intermediate" : "—"))
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(Color.secondary.opacity(0.2), in: Capsule())
                    if recording.hasReference {
                        Label("HEVC ref", systemImage: "link").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(Color.secondary.opacity(0.2), in: Capsule())
                    }
                    if recording.droppedFrames + recording.sourceDroppedFrames > 0 {
                        Label("\(recording.droppedFrames + recording.sourceDroppedFrames) dropped", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.red.opacity(0.2), in: Capsule()).foregroundStyle(.red)
                    }
                    if recording.pipelineFailure != nil {
                        Label("stopped early", systemImage: "xmark.octagon.fill")
                            .font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.red.opacity(0.2), in: Capsule()).foregroundStyle(.red)
                    }
                    VerificationBadge(state: recording.verification, stage2: recording.stage2,
                                      job: stage2.jobs.first(where: { $0.baseName == recording.baseName && !$0.finished }))
                }
            }
        }
    }
}

struct RecordingDetailView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var stage2: Stage2Runner
    @EnvironmentObject var settings: SettingsStore
    let recordingID: String
    @State private var compareWithID: String?
    @State private var showPicker = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    private var recording: Recording? { library.recordings.first { $0.baseName == recordingID } }
    private func recording(named id: String) -> Recording? { library.recordings.first { $0.baseName == id } }

    var body: some View {
        if let r = recording {
            List {
                Section {
                    ThumbnailView(recording: r).frame(maxWidth: .infinity, alignment: .center).scaleEffect(2.4).frame(height: 140)
                    VerificationBadge(state: r.verification, stage2: r.stage2, job: stage2.jobs.first(where: { $0.baseName == r.baseName && !$0.finished }))
                    if let job = stage2.jobs.first(where: { $0.baseName == r.baseName && !$0.finished }) {
                        ProgressView(value: job.progress) { Text(job.paused ? job.phase + " (paused while recording)" : job.phase).font(.caption) }
                    }
                }
                if r.droppedFrames > 0 || r.pipelineFailure != nil {
                    Section {
                        if let f = r.pipelineFailure {
                            Label(f, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                        }
                        if r.droppedFrames > 0 {
                            let kept = r.keptFraction.map { String(format: " (%.0f%% of the delivered frames kept)", $0 * 100) } ?? ""
                            Label(String(format: "%lld frames were dropped during capture%@. The file keeps the real %.1f s timeline with gaps; it holds %.1f s of footage. The HEVC reference is continuous.", r.droppedFrames, kept, r.durationSeconds, r.contentDuration), systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                            Text("To keep every frame: lower the resolution or frame rate, run the stage-1 benchmark (Settings → Lossless pipeline), free storage, or let a running stage-2 job finish before recording.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } header: { Text("Capture warnings") }
                }
                Section("Actions") {
                    if let mkv = r.mkvURL, r.isReady {
                        NavigationLink("Play lossless MKV") { PlayerView(url: mkv, title: r.baseName) }
                        if let ref = r.referenceURL {
                            NavigationLink("Compare with HEVC reference") { ComparisonView(urlA: mkv, urlB: ref, titleA: "FFV1 lossless", titleB: "HEVC reference") }
                        }
                        Button("Compare with another recording…") { showPicker = true }
                        Button(stage2.isBusy(baseName: r.baseName) ? "Verification running…" : "Verify again (decode + rehash)") {
                            Stage2Runner.shared.enqueueVerification(recording: r)
                        }.disabled(stage2.isBusy(baseName: r.baseName))
                    }
                    if let ref = r.referenceURL {
                        NavigationLink("Play HEVC reference") { PlayerView(url: ref, title: r.baseName + " (HEVC)") }
                    }
                    if r.files.intermediate != nil, !stage2.isBusy(baseName: r.baseName) {
                        Button(r.files.mkv == nil ? "Run stage 2 now" : "Run stage 2 again (rebuild MKV from the intermediate)") {
                            Stage2Runner.shared.enqueue(recording: r, ffv1: settings.settings.ffv1Params, flacLevel: settings.settings.flacCompressionLevel, metadata: ["LOSSLESSCAM_STAGE2", "manual"])
                        }
                    }
                    if stage2.isBusy(baseName: r.baseName) { Button("Cancel stage 2 / verification", role: .destructive) { Stage2Runner.shared.cancel(baseName: r.baseName) } }
                    Button("Delete recording", role: .destructive) { confirmDelete = true }
                }
                Section("Verification") {
                    let v = r.verification
                    row("Status", v.status.rawValue.uppercased())
                    row("Video", "\(v.videoStatus.rawValue) · \(v.framesChecked)/\(v.framesExpected) frames" + (v.firstMismatchFrame >= 0 ? " · first mismatch at frame \(v.firstMismatchFrame)" : ""))
                    row("Audio", "\(v.audioStatus.rawValue) · \(v.audioFramesChecked) sample frames" + (v.audioFirstMismatchFrame >= 0 ? " · mismatch near frame \(v.audioFirstMismatchFrame)" : ""))
                    row("FFV1 slice CRC", v.sliceCrcChecked ? "checked by decoder · \(v.crcErrors) errors" : "not checked")
                    if let d = v.checkedAt { row("Checked", d.formatted(date: .abbreviated, time: .shortened) + String(format: " (%.1f s)", v.seconds)) }
                    if let m = v.message { Text(m).font(.caption).foregroundStyle(.orange) }
                    Text("Every decoded frame is re-packed to the capture layout and XXH64-hashed; hashes must equal those computed on the frames AVFoundation delivered. Audio is hashed as one continuous 24-bit stream with checkpoints.").font(.caption2).foregroundStyle(.secondary)
                }
                Section("Recording") {
                    row("Created", r.createdAt.formatted(date: .abbreviated, time: .standard))
                    row("Video", "\(r.width)×\(r.height) · \(r.fps) fps · \(r.bitDepth)-bit · \(r.fullRange ? "full" : "video") range · source \(r.pixelFormatFourCC)")
                    row("Colour", r.colorDescription)
                    row("Timeline", String(format: "%.2f s (first to last kept frame) · footage %.2f s (%lld frames ÷ %ld fps)", r.durationSeconds, r.contentDuration, r.frameCount, r.fps))
                    row("Frames", "\(r.frameCount) written · \(r.deliveredFrames.map { "\($0) delivered · " } ?? "")\(r.droppedFrames) dropped by pipeline · \(r.sourceDroppedFrames) dropped by source")
                    row("Mode", r.captureMode + (r.stage1Codec.map { " · stage 1 \($0)" } ?? ""))
                    row("Preset", "\(r.preset) · stabilization \(r.stabilization)")
                    if let a = r.audio {
                        row("Audio", "\(a.channels) ch · \(a.sampleRate) Hz · 24-bit FLAC" + (a.ambisonic ? " · first-order ambisonics (ACN/SN3D)" : ""))
                        row("Audio source", a.sourceFormat + (a.inexactSamples > 0 ? " · \(a.inexactSamples) samples needed quantisation" : " · exact"))
                        if a.trimmedFrames > 0 || a.discontinuities > 0 || a.silenceFramesInserted > 0 {
                            row("Audio timing", "\(a.trimmedFrames) pre-roll frames trimmed · \(a.discontinuities) discontinuities · \(a.silenceFramesInserted) silence frames inserted")
                        }
                    } else { row("Audio", "none") }
                    row("Reference", r.referencePath)
                    if r.lowBitsNonZero { Text("Padding bits of the 10-bit samples were non-zero in the source buffers; only the 10-bit values are stored.").font(.caption).foregroundStyle(.orange) }
                    row("Telemetry", String(format: "avg %.1f fps · avg %.0f MB/s · peak buffer %.0f%% · thermal max %ld · %ld memory warnings", r.telemetry.averageFps, r.telemetry.averageWriteMBps, r.telemetry.peakBufferFill * 100, r.telemetry.maxThermalState, r.telemetry.memoryWarnings))
                    if r.stage2.status != .notNeeded {
                        row("Stage 2", "\(r.stage2.status.rawValue)" + (r.stage2.seconds > 0 ? String(format: " · %.1f s", r.stage2.seconds) : "") + (r.stage2.intermediateHashMismatches > 0 ? " · \(r.stage2.intermediateHashMismatches) intermediate hash mismatches" : "") + (r.stage2.error.map { " · \($0)" } ?? ""))
                    }
                    if let n = r.notes { Text(n).font(.caption2).foregroundStyle(.secondary) }
                }
                Section("Files (Documents folder — Files app → On My iPhone → LosslessCam, or USB)") {
                    if let m = r.files.mkv { row("MKV", "\(m) · \(r.fileSizeBytes.byteCountString)") }
                    if let h = r.files.hevcReference { row("HEVC", "\(h) · \(r.referenceSizeBytes.byteCountString)") }
                    row("Hash list", r.files.hashList)
                    if let i = r.files.intermediate { row("Intermediate", i + " (kept until the MKV verifies)") }
                    row("Sidecar", r.baseName + ".json")
                }
            }
            .navigationTitle(r.resolutionLabel + " " + r.createdAt.formatted(date: .numeric, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPicker) {
                RecordingPicker(exclude: r.baseName) { other in compareWithID = other.baseName }
            }
            .navigationDestination(item: $compareWithID) { otherID in
                if let other = recording(named: otherID), let a = r.mkvURL, let b = other.mkvURL {
                    ComparisonView(urlA: a, urlB: b, titleA: r.baseName, titleB: other.baseName)
                } else {
                    ContentUnavailableView("Recording not found", systemImage: "questionmark.folder")
                }
            }
            .confirmationDialog("Delete this recording and its files?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { library.delete(r); dismiss() }
            }
        } else {
            ContentUnavailableView("Recording not found", systemImage: "questionmark.folder")
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.caption.monospacedDigit())
        }
    }
}

struct RecordingPicker: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let exclude: String
    let onPick: (Recording) -> Void
    var body: some View {
        NavigationStack {
            List(library.recordings.filter { $0.baseName != exclude && $0.mkvURL != nil && $0.isReady }) { r in
                Button { onPick(r); dismiss() } label: { RecordingRow(recording: r) }.buttonStyle(.plain)
            }
            .navigationTitle("Compare with…")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct CompareAnyPicker: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var a: String = ""
    @State private var b: String = ""
    @State private var go = false

    private var ready: [Recording] { library.recordings.filter { $0.isReady } }
    private func rec(_ id: String) -> Recording? { ready.first { $0.baseName == id } }

    var body: some View {
        NavigationStack {
            Form {
                Picker("A", selection: $a) {
                    Text("—").tag("")
                    ForEach(ready) { r in Text(r.baseName).font(.caption).tag(r.baseName) }
                }
                Picker("B", selection: $b) {
                    Text("—").tag("")
                    ForEach(ready) { r in Text(r.baseName).font(.caption).tag(r.baseName) }
                }
                Button("Open comparison") { go = true }.disabled(rec(a) == nil || rec(b) == nil)
            }
            .navigationTitle("Compare any two")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(isPresented: $go) {
                if let ra = rec(a), let rb = rec(b), let ua = ra.mkvURL, let ub = rb.mkvURL {
                    ComparisonView(urlA: ua, urlB: ub, titleA: ra.baseName, titleB: rb.baseName)
                } else {
                    ContentUnavailableView("Pick two recordings", systemImage: "rectangle.on.rectangle")
                }
            }
        }
    }
}
