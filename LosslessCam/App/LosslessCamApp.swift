import SwiftUI

@main
struct LosslessCamApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var capture = CaptureManager()
    @StateObject private var library = LibraryStore()
    @StateObject private var benchmark = BenchmarkRunner()
    @StateObject private var stage2 = Stage2Runner.shared

    init() {
        lc_bridge_init()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(capture)
                .environmentObject(library)
                .environmentObject(benchmark)
                .environmentObject(stage2)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var capture: CaptureManager
    @EnvironmentObject var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var resumedPending = false

    private var isRecording: Bool { capture.state == .recording || capture.state == .finishing }

    /// While recording, the Capture tab stays selected: the player and library would compete
    /// with the storage pipeline for CPU, memory bandwidth and the audio session.
    private var tabSelection: Binding<Int> {
        Binding(get: { tab }, set: { newValue in if !isRecording { tab = newValue } })
    }

    var body: some View {
        TabView(selection: tabSelection) {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "camera") }
                .tag(0)
            LibraryView()
                .tabItem { Label("Library", systemImage: "film.stack") }
                .tag(1)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(2)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .task {
            await capture.requestPermissions()
            capture.configure(settings: settings.settings)
        }
        .onChange(of: capture.state) { _, newState in
            if newState == .recording { tab = 0 }
        }
        .onChange(of: scenePhase) { _, phase in
            // Jobs interrupted by the background-time limit continue when the app is back.
            if phase == .active && resumedPending {
                library.refresh()
                Stage2Runner.shared.resumePending(recordings: library.recordings, ffv1: settings.settings.ffv1Params, flacLevel: settings.settings.flacCompressionLevel)
            }
        }
        .onReceive(library.$scanning) { scanning in
            // Resume interrupted stage-2 jobs once the first library scan has completed.
            if !scanning, !resumedPending {
                resumedPending = true
                Stage2Runner.shared.resumePending(recordings: library.recordings, ffv1: settings.settings.ffv1Params, flacLevel: settings.settings.flacCompressionLevel)
            }
        }
    }
}
