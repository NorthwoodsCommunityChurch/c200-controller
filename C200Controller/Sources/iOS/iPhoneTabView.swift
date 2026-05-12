import SwiftUI

/// iPhone-specific layout: TabView with Cameras / Presets / Tally / Settings.
/// Matches the iPhone mockup in docs/ui-redesign-preview.html.
///
/// iPad uses NavigationSplitView (see MobileContentView). MobileContentView
/// switches on horizontalSizeClass to pick the right layout per device.
struct iPhoneTabView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var presetManager: PresetManager
    @State private var selectedTab: iPhoneTab = .cameras

    enum iPhoneTab: Hashable {
        case cameras, presets, tally, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                iPhoneCamerasTab()
                    .environmentObject(cameraManager)
                    .environmentObject(presetManager)
            }
            .tabItem {
                Label("Cameras", systemImage: "video.fill")
            }
            .tag(iPhoneTab.cameras)

            NavigationStack {
                MobilePresetsView()
                    .environmentObject(presetManager)
                    .environmentObject(cameraManager)
            }
            .tabItem {
                Label("Presets", systemImage: "slider.horizontal.3")
            }
            .tag(iPhoneTab.presets)

            NavigationStack {
                iPhoneTallyTab()
                    .environmentObject(cameraManager)
            }
            .tabItem {
                Label("Tally", systemImage: "antenna.radiowaves.left.and.right")
            }
            .tag(iPhoneTab.tally)

            NavigationStack {
                MobileSettingsView()
                    .environmentObject(cameraManager)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(iPhoneTab.settings)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Cameras tab (vertical list)

struct iPhoneCamerasTab: View {
    @EnvironmentObject var cameraManager: CameraManager
    @State private var showingAddCamera = false

    private var connectedCount: Int {
        cameraManager.cameraStates.values.filter { $0.isConnected }.count
    }
    private var recordingCount: Int {
        cameraManager.cameraStates.values.filter { $0.isRecording }.count
    }

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(cameraManager.cameras) { camera in
                        if let state = cameraManager.cameraStates[camera.id] {
                            NavigationLink {
                                iPhoneCameraDetailView(cameraId: camera.id)
                                    .environmentObject(cameraManager)
                            } label: {
                                iPhoneCameraRow(camera: camera, state: state)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    iPhoneAddCameraRow {
                        showingAddCamera = true
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Cameras")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Text(subtitle)
                } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showingAddCamera) {
            AddCameraSheet()
                .environmentObject(cameraManager)
                .onAppear { cameraManager.refreshDiscovery() }
        }
    }

    private var subtitle: String {
        var parts = ["\(connectedCount) connected"]
        if recordingCount > 0 { parts.append("\(recordingCount) recording") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Camera row (compact card for iPhone list)

struct iPhoneCameraRow: View {
    let camera: Camera
    @ObservedObject var state: CameraState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(camera.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Text(subline)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                tallyChips
            }

            if state.isConnected {
                HStack(spacing: 6) {
                    smallMetric("Av", state.aperture)
                    smallMetric("ISO", state.iso)
                    smallMetric("Tv", state.shutter)
                    smallMetric("WB", state.wbKelvin)
                    smallMetric("ND", state.ndFilter)
                }
            } else {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).tint(Theme.label2)
                    Text("Offline · reconnecting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .shadow(color: glowColor, radius: glowRadius)
        .opacity(state.isConnected ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.15), value: state.tallyProgram)
        .animation(.easeInOut(duration: 0.15), value: state.tallyPreview)
    }

    private var subline: String {
        var parts = [camera.ip]
        if camera.tslIndex > 0 { parts.append("TSL \(camera.tslIndex)") }
        if state.isRecording { parts.append("REC") }
        return parts.joined(separator: " · ")
    }

    private var tallyChips: some View {
        HStack(spacing: 5) {
            if state.tallyProgram {
                miniChip("PGM", color: Theme.red)
            }
            if state.tallyPreview {
                miniChip("PVW", color: Theme.green)
            }
            if !state.tallyProgram && !state.tallyPreview && state.isConnected {
                miniChip("OFF", color: Theme.label3, dim: true)
            }
        }
    }

    private func miniChip(_ label: String, color: Color, dim: Bool = false) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: dim ? .clear : color, radius: 4)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(dim ? Color.white.opacity(0.06) : color.opacity(0.18), in: Capsule())
    }

    private func smallMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .padding(.horizontal, 3)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.label4, lineWidth: 0.5)
        )
    }

    private var borderColor: Color {
        if state.tallyProgram { return Theme.red }
        if state.tallyPreview { return Theme.green }
        return Theme.label4
    }
    private var borderWidth: CGFloat {
        (state.tallyProgram || state.tallyPreview) ? 1.5 : 1
    }
    private var glowColor: Color {
        if state.tallyProgram { return Theme.red.opacity(0.45) }
        if state.tallyPreview { return Theme.green.opacity(0.35) }
        return .clear
    }
    private var glowRadius: CGFloat {
        (state.tallyProgram || state.tallyPreview) ? 14 : 0
    }
}

struct iPhoneAddCameraRow: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.bgCardElevated).frame(width: 44, height: 44)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.label)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add camera")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.label)
                    Text("Discover or enter IP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.label3)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Theme.label4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tally tab — TSL listener config + per-camera force buttons

struct iPhoneTallyTab: View {
    @EnvironmentObject var cameraManager: CameraManager
    @State private var portText: String = ""
    @State private var brightness: Double = 1
    @State private var brightnessDebounce: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { cameraManager.tslEnabled },
                        set: { e in if e { cameraManager.startTSL() } else { cameraManager.stopTSL() } }
                    )) {
                        Label("TSL Listener", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                            .shadow(color: statusColor.opacity(0.6), radius: 3)
                        Text(statusText)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Spacer()
                    }
                    HStack {
                        Text("TCP Port")
                        Spacer()
                        TextField("5200", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .font(.body.monospaced())
                            .onSubmit { commitPort() }
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("LED Brightness")
                            Spacer()
                            Text("\(Int(brightness))%")
                                .foregroundStyle(.secondary)
                                .font(.body.monospaced())
                        }
                        Slider(value: $brightness, in: 1...100, step: 1)
                            .tint(Theme.accent)
                            .onChange(of: brightness) { _, new in
                                UserDefaults.standard.set(Int(new), forKey: "tally_brightness")
                                brightnessDebounce?.cancel()
                                brightnessDebounce = Task {
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    if Task.isCancelled { return }
                                    pushBrightness(Int(new))
                                }
                            }
                    }
                    Toggle("Swap Program / Preview", isOn: $cameraManager.tslSwapProgramPreview)
                } header: {
                    Text("TSL Listener")
                }

                Section {
                    ForEach(cameraManager.cameras.filter { $0.connectionType == .esp32 }) { camera in
                        if let state = cameraManager.cameraStates[camera.id] {
                            tallyForceRow(camera: camera, state: state)
                        }
                    }
                } header: {
                    Text("Force tally state")
                } footer: {
                    Text("Useful for testing wiring or verifying which board is which.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Tally")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            portText = String(cameraManager.tslPort)
            let saved = UserDefaults.standard.integer(forKey: "tally_brightness")
            brightness = Double(saved == 0 ? 1 : saved)
        }
    }

    private func tallyForceRow(camera: Camera, state: CameraState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(camera.name).font(.body.weight(.medium))
                Spacer()
                if camera.tslIndex > 0 {
                    Text("TSL \(camera.tslIndex)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                forceButton("PGM", color: Theme.red) {
                    state.updateTallyState(program: true, preview: false)
                }
                forceButton("PVW", color: Theme.green) {
                    state.updateTallyState(program: false, preview: true)
                }
                forceButton("OFF", color: Theme.label3) {
                    state.updateTallyState(program: false, preview: false)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func forceButton(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func commitPort() {
        guard let port = UInt16(portText), port > 0, port != cameraManager.tslPort else {
            portText = String(cameraManager.tslPort)
            return
        }
        let wasEnabled = cameraManager.tslEnabled
        if wasEnabled { cameraManager.stopTSL() }
        cameraManager.tslPort = port
        if wasEnabled { cameraManager.startTSL() }
    }

    private func pushBrightness(_ percent: Int) {
        let value = Int(Double(percent) / 100.0 * 255.0)
        for camera in cameraManager.cameras where camera.connectionType == .esp32 {
            if let state = cameraManager.cameraStates[camera.id] {
                Task { await state.sendBrightness(value) }
            }
        }
    }

    private var statusColor: Color {
        if cameraManager.tslClientConnected { return Theme.green }
        if cameraManager.tslListening { return Theme.yellow }
        return Theme.label3
    }
    private var statusText: String {
        if cameraManager.tslClientConnected { return "Switcher connected" }
        if cameraManager.tslListening { return "Listening on :\(cameraManager.tslPort)" }
        return "Off"
    }
}
