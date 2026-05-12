import SwiftUI

struct MobileContentView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var presetManager: PresetManager
    @State private var selection: SidebarItem? = .allCameras
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .environmentObject(cameraManager)
                .environmentObject(presetManager)
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
        } detail: {
            detailView
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.bgPrimary)
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .allCameras {
        case .allCameras:
            CameraGridView()
                .environmentObject(cameraManager)
        case .presets:
            PresetsPlaceholder()
                .environmentObject(presetManager)
        case .settings:
            SettingsPlaceholder()
                .environmentObject(cameraManager)
        }
    }
}

// MARK: - Camera grid (the main view)

struct CameraGridView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @State private var detailCameraId: String?
    @State private var showingAddCamera = false

    private var connectedCount: Int {
        cameraManager.cameraStates.values.filter { $0.isConnected }.count
    }
    private var recordingCount: Int {
        cameraManager.cameraStates.values.filter { $0.isRecording }.count
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)]
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bgPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
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
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                }
            }
        }
        .sheet(item: Binding(
            get: { detailCameraId.map { CameraIDBox(id: $0) } },
            set: { detailCameraId = $0?.id }
        )) { box in
            CameraDetailSheet(cameraId: box.id)
                .environmentObject(cameraManager)
        }
        .sheet(isPresented: $showingAddCamera) {
            AddCameraSheet()
                .environmentObject(cameraManager)
                .onAppear { cameraManager.refreshDiscovery() }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cameras")
                    .font(.system(size: 28, weight: .bold))
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
        }
        .padding(.horizontal, 20)
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
            let port = cameraManager.tslPort
            return "\(connected) · TSL listening on :\(port)"
        }
        return "\(connected) · TSL off"
    }

    private var tslPill: some View {
        let connected = cameraManager.tslClientConnected
        let listening = cameraManager.tslListening
        let color: Color = connected ? Theme.green : (listening ? Theme.yellow : Theme.label3)
        let label: String = connected ? "TSL · Live" : (listening ? "TSL · Listening" : "TSL · Off")
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
}

// MARK: - Add-camera card (tap to open add sheet)

struct AddCameraCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.bgCard)
                        .frame(width: 44, height: 44)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.label)
                }
                Text("Add camera")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.label2)
                Text("Discover or enter IP")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.label3)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Theme.label4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Identifiable wrapper so `.sheet(item:)` can drive presentation from a String id.
struct CameraIDBox: Identifiable {
    let id: String
}

// MARK: - Placeholders (Phase 2/3)

struct PresetsPlaceholder: View {
    @EnvironmentObject var presetManager: PresetManager
    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            ContentUnavailableView(
                "Presets",
                systemImage: "slider.horizontal.3",
                description: Text("\(presetManager.presets.count) preset(s) — full UI lands in Phase 3.")
            )
            .tint(Theme.accent)
        }
    }
}

struct SettingsPlaceholder: View {
    @EnvironmentObject var cameraManager: CameraManager
    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            ContentUnavailableView(
                "Settings",
                systemImage: "gearshape",
                description: Text("TSL, firmware update, camera positions — wired up in Phase 3.")
            )
        }
    }
}

#Preview {
    MobileContentView()
        .environmentObject(CameraManager())
        .environmentObject(PresetManager())
}
