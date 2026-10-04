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
    @State private var tab = 0
    @State private var resumedPending = false

    var body: some View {
        TabView(selection: $tab) {
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
        .onReceive(library.$scanning) { scanning in
            // Resume interrupted stage-2 jobs once the first library scan has completed.
            if !scanning, !resumedPending, !library.recordings.isEmpty {
                resumedPending = true
                Stage2Runner.shared.resumePending(recordings: library.recordings, ffv1: settings.settings.ffv1Params, flacLevel: settings.settings.flacCompressionLevel)
            }
        }
    }
}
