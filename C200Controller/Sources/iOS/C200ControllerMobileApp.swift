import SwiftUI

@main
struct C200ControllerMobileApp: App {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var presetManager = PresetManager()

    init() {
        appLog("=== C200 Controller (iOS) started ===")
    }

    var body: some Scene {
        WindowGroup {
            MobileContentView()
                .environmentObject(cameraManager)
                .environmentObject(presetManager)
                .preferredColorScheme(.dark)
        }
    }
}
