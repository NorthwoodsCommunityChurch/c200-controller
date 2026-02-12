import SwiftUI

@main
struct C200ControllerApp: App {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var presetManager = PresetManager()

    init() {
        // Clear old log and write startup marker
        try? FileManager.default.removeItem(atPath: logPath)
        appLog("=== C200 Controller started ===")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cameraManager)
                .environmentObject(presetManager)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1150, height: 700)
    }
}
