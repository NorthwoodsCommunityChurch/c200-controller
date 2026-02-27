import SwiftUI
import Sparkle

@main
struct C200ControllerApp: App {
    private let updaterController: SPUStandardUpdaterController
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var presetManager = PresetManager()
    @State private var showingTallySettings = false
    @State private var showingFirmwareUpdate = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Clear old log and write startup marker
        try? FileManager.default.removeItem(atPath: logPath)
        appLog("=== C200 Controller started ===")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cameraManager)
                .environmentObject(presetManager)
                .sheet(isPresented: $showingTallySettings) {
                    TallySettingsView()
                        .environmentObject(cameraManager)
                }
                .sheet(isPresented: $showingFirmwareUpdate) {
                    FirmwareUpdateView()
                        .environmentObject(cameraManager)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1150, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .appSettings) {
                Button("Tally Settings...") {
                    showingTallySettings = true
                }
                .keyboardShortcut("T", modifiers: [.command, .shift])

                Button("Firmware Update...") {
                    showingFirmwareUpdate = true
                }
                .keyboardShortcut("U", modifiers: [.command, .shift])
            }
        }
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates...") { updater.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}
