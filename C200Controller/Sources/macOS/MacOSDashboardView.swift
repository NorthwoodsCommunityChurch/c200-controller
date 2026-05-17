import SwiftUI

/// New macOS dashboard built on the iPad design language. Lives behind a
/// `useNewDashboard` toggle (⌘⇧M) until verified against a live production
/// session. The legacy `ContentView` remains the default — see
/// `C200ControllerApp.swift` for the switch.
///
/// Goals for this view:
///   - Reuse CameraCardView (Shared) so the macOS tiles match iPad pixel-for-pixel.
///   - Preserve every menu-bar entry point (⌘⇧T / ⌘⇧U / ⌘⇧P / ⌘⇧D).
///   - Stay out of the production tally path: this is presentation only.
struct MacOSDashboardView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var presetManager: PresetManager

    @State private var sidebarSelection: MacSidebarItem? = .allCameras
    @State private var detailCameraId: String?
    @State private var showingAddCamera = false
    @State private var showingTallySettings = false
    @State private var showingTSLDiagnostics = false
    @State private var showingFirmwareUpdate = false
    @State private var showingPositionsSettings = false

    var body: some View {
        NavigationSplitView {
            MacOSSidebar(selection: $sidebarSelection)
                .environmentObject(cameraManager)
                .environmentObject(presetManager)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.bgPrimary)
        .tint(Theme.accent)
        .sheet(isPresented: $showingTallySettings) {
            TallySettingsView()
                .environmentObject(cameraManager)
        }
        .sheet(isPresented: $showingTSLDiagnostics) {
            TSLDiagnosticsView()
                .environmentObject(cameraManager)
        }
        .sheet(isPresented: $showingFirmwareUpdate) {
            FirmwareUpdateView()
                .environmentObject(cameraManager)
        }
        .sheet(isPresented: $showingPositionsSettings) {
            CameraPositionsSettingsView()
                .environmentObject(cameraManager)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        switch sidebarSelection ?? .allCameras {
        case .allCameras:
            cameraGridPane
        case .presets:
            // Reuse the existing PresetsPanel — it already provides full preset
            // management. Wrapped in a black background to match the new palette.
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()
                PresetsPanel()
                    .environmentObject(presetManager)
                    .environmentObject(cameraManager)
            }
        case .tally:
            TallySourcesView(
                showingTSLDiagnostics: $showingTSLDiagnostics,
                showingTallySettings: $showingTallySettings
            )
            .environmentObject(cameraManager)
        }
    }

    private var cameraGridPane: some View {
        ZStack(alignment: .top) {
            Theme.bgPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 16)],
                              spacing: 16) {
                        ForEach(cameraManager.cameras) { camera in
                            if let state = cameraManager.cameraStates[camera.id] {
                                CameraCardView(camera: camera, state: state) {
                                    detailCameraId = camera.id
                                }
                            }
                        }
                        AddCameraCard {
                            showingAddCamera = true
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                }
            }
        }
        .sheet(isPresented: $showingAddCamera) {
            AddCameraSheet()
                .environmentObject(cameraManager)
                .onAppear { cameraManager.refreshDiscovery() }
        }
        .sheet(item: Binding(
            get: { detailCameraId.map { CameraIDBox(id: $0) } },
            set: { detailCameraId = $0?.id }
        )) { box in
            CameraDetailSheet(cameraId: box.id)
                .environmentObject(cameraManager)
        }
    }

    // MARK: - Top bar (matches iPad CameraGridView style)

    private var connectedCount: Int {
        cameraManager.cameraStates.values.filter { $0.isConnected }.count
    }
    private var recordingCount: Int {
        cameraManager.cameraStates.values.filter { $0.isRecording }.count
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cameras")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.label)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.label2)
            }
            Spacer()
            tslPill
            if recordingCount > 0 {
                recordingPill
            }
            toolbarButtons
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.label4)
                .frame(height: 0.5)
        }
    }

    private var subtitle: String {
        let connected = "\(connectedCount) connected"
        if cameraManager.tslEnabled {
            return "\(connected) · TSL listening on :\(cameraManager.tslPort)"
        }
        return "\(connected) · TSL off"
    }

    private var tslPill: some View {
        let connected = cameraManager.tslClientConnected
        let listening = cameraManager.tslListening
        let color: Color = connected ? Theme.green : (listening ? Theme.yellow : Theme.label3)
        let label = connected ? "TSL · Live" : (listening ? "TSL · Listening" : "TSL · Off")
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(color.opacity(0.18), in: Capsule())
    }

    private var recordingPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.red)
                .frame(width: 7, height: 7)
            Text("\(recordingCount) recording")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Theme.red)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Theme.redTint, in: Capsule())
    }

    private var toolbarButtons: some View {
        HStack(spacing: 4) {
            iconButton("stethoscope", help: "TSL Status (⌘⇧D)") {
                showingTSLDiagnostics = true
            }
            iconButton("gearshape", help: "TSL Settings (⌘⇧T)") {
                showingTallySettings = true
            }
            iconButton("location.viewfinder", help: "Camera Positions (⌘⇧P)") {
                showingPositionsSettings = true
            }
            iconButton("arrow.up.circle", help: "Firmware Update (⌘⇧U)") {
                showingFirmwareUpdate = true
            }
        }
        .padding(.leading, 4)
    }

    private func iconButton(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14))
                .foregroundStyle(Theme.label2)
                .frame(width: 30, height: 28)
                .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }

}

// MARK: - Sidebar (macOS-tailored — no iOS-only modifiers)

enum MacSidebarItem: Hashable {
    case allCameras
    case presets
    case tally
}

struct MacOSSidebar: View {
    @Binding var selection: MacSidebarItem?
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var presetManager: PresetManager

    private var connectedCount: Int {
        cameraManager.cameraStates.values.filter { $0.isConnected }.count
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                MacAppIdentityRow()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            Section {
                Label("Cameras", systemImage: "video.fill")
                    .tag(MacSidebarItem.allCameras)
                Label("Presets", systemImage: "slider.horizontal.3")
                    .tag(MacSidebarItem.presets)
                Label("Tally", systemImage: "dot.radiowaves.left.and.right")
                    .tag(MacSidebarItem.tally)
            }

            Section("Cameras · \(connectedCount) of \(cameraManager.cameras.count)") {
                if cameraManager.cameras.isEmpty {
                    Text("No cameras yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(cameraManager.cameras) { camera in
                        MacSidebarCameraRow(
                            camera: camera,
                            state: cameraManager.cameraStates[camera.id]
                        )
                    }
                }
            }

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
    }
}

private struct MacAppIdentityRow: View {
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
                    .font(.system(size: 13, weight: .semibold))
                Text("Dashboard · preview")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MacSidebarCameraRow: View {
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
                    .font(.system(size: 13))
                    .foregroundStyle(isOffline ? .secondary : .primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(isOffline ? "offline" : camera.ip)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
