import SwiftUI

enum SidebarItem: Hashable {
    case allCameras
    case presets
    case settings
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var presetManager: PresetManager

    private var connectedCount: Int {
        cameraManager.cameraStates.values.filter { $0.isConnected }.count
    }

    var body: some View {
        List(selection: $selection) {
            // App identity
            Section {
                AppIdentityRow()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
            }

            // Main navigation
            Section {
                Label("Cameras", systemImage: "video.fill")
                    .tag(SidebarItem.allCameras)
                Label("Presets", systemImage: "slider.horizontal.3")
                    .tag(SidebarItem.presets)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }

            // Live camera roster — visual only, shows tally state
            Section("Cameras · \(connectedCount) of \(cameraManager.cameras.count)") {
                if cameraManager.cameras.isEmpty {
                    Text("No cameras yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(cameraManager.cameras) { camera in
                        SidebarCameraRow(
                            camera: camera,
                            state: cameraManager.cameraStates[camera.id]
                        )
                    }
                }
            }

            // Presets roster
            if !presetManager.presets.isEmpty {
                Section("Presets") {
                    ForEach(presetManager.presets, id: \.id) { preset in
                        Label(preset.name, systemImage: "slider.horizontal.below.rectangle")
                            .lineLimit(1)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("C200")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sidebar rows

struct AppIdentityRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Theme.accent, Theme.indigo],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 32, height: 32)
                Image(systemName: "video.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("C200 Controller")
                    .font(.system(size: 14, weight: .semibold))
                Text("v1.0 · iPad")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct SidebarCameraRow: View {
    let camera: Camera
    let state: CameraState?

    private var tallyColor: Color {
        guard let state else { return Color.gray.opacity(0.4) }
        if state.tallyProgram { return Theme.red }
        if state.tallyPreview { return Theme.green }
        if !state.isConnected { return Color.gray.opacity(0.4) }
        return Color.gray.opacity(0.6)
    }

    private var isOffline: Bool {
        state?.isConnected != true
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tallyColor)
                .frame(width: 10, height: 10)
                .shadow(color: tallyColor.opacity(0.6),
                        radius: (state?.tallyProgram == true || state?.tallyPreview == true) ? 6 : 0)
            VStack(alignment: .leading, spacing: 0) {
                Text(camera.name)
                    .font(.system(size: 14))
                    .foregroundStyle(isOffline ? .secondary : .primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(isOffline ? "offline" : camera.ip)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
