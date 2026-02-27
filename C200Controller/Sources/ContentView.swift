import SwiftUI

struct ContentView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var presetManager: PresetManager

    var body: some View {
        HStack(spacing: 0) {
            // Presets sidebar
            PresetsPanel()
                .environmentObject(presetManager)
                .environmentObject(cameraManager)

            Divider()

            // Main content
            ZStack {
                Color.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    HeaderView()

                    // Main Content - Grid of camera tiles
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 16)
                        ], spacing: 16) {
                            // Camera tiles for each known camera
                            ForEach(cameraManager.cameras) { camera in
                                if let state = cameraManager.cameraStates[camera.id] {
                                    CameraTile(camera: camera, state: state)
                                        .environmentObject(cameraManager)
                                        .environmentObject(presetManager)
                                }
                            }

                            // Add Camera tile (always last)
                            AddCameraTile()
                        }
                        .padding(20)
                    }
                }
            }
        }
        .onAppear {
            appLog("=== C200 Controller UI appeared ===")
            appLog("logPath=\(logPath)")
            appLog("Cameras: \(cameraManager.cameras.count), Presets: \(presetManager.presets.count)")
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @State private var showingFirmwareUpdate = false
    @State private var showingTallySettings = false

    private var connectedCount: Int {
        cameraManager.cameraStates.values.filter { $0.isConnected }.count
    }

    private var recordingCount: Int {
        cameraManager.cameraStates.values.filter { $0.isRecording }.count
    }

    private var tslStatusColor: Color {
        if cameraManager.tslClientConnected { return .success }
        if cameraManager.tslListening { return .warning }
        return Color(white: 0.35)
    }

    private var tslStatusHelp: String {
        if cameraManager.tslClientConnected { return "TSL: Switcher connected" }
        if cameraManager.tslListening { return "TSL: Listening on port \(cameraManager.tslPort)..." }
        return "TSL: Off"
    }

    var body: some View {
        HStack {
            Text("Canon C200 Controller")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.textPrimary)

            Spacer()

            // Summary status
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectedCount > 0 ? Color.success : Color.error)
                        .frame(width: 8, height: 8)
                    Text("\(connectedCount) Camera\(connectedCount == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundColor(.textSecondary)
                }

                if recordingCount > 0 {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.error)
                            .frame(width: 8, height: 8)
                        Text("\(recordingCount) Recording")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.error)
                    }
                }

                // TSL status + toggle + settings
                HStack(spacing: 6) {
                    Circle()
                        .fill(tslStatusColor)
                        .frame(width: 8, height: 8)
                        .help(tslStatusHelp)
                    Text("TSL")
                        .font(.system(size: 12))
                        .foregroundColor(.textSecondary)
                    Toggle("", isOn: Binding(
                        get: { cameraManager.tslEnabled },
                        set: { enabled in
                            if enabled { cameraManager.startTSL() }
                            else { cameraManager.stopTSL() }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    Button {
                        showingTallySettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .foregroundColor(.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("TSL Settings (⌘⇧T)")
                }

                Button {
                    showingFirmwareUpdate = true
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Firmware Update (⌘⇧U)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color.backgroundSecondary)
        .sheet(isPresented: $showingTallySettings) {
            TallySettingsView()
                .environmentObject(cameraManager)
        }
        .sheet(isPresented: $showingFirmwareUpdate) {
            FirmwareUpdateView()
                .environmentObject(cameraManager)
        }
    }
}

// MARK: - Add Camera Tile

struct AddCameraTile: View {
    @EnvironmentObject var cameraManager: CameraManager
    @State private var connectionTab = 0  // 0 = ESP32, 1 = Direct
    @State private var manualIP = ""
    @State private var directCameraIP = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "plus.circle")
                    .font(.system(size: 16))
                Text("ADD CAMERA")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1)
            }
            .foregroundColor(.textSecondary)

            // Tab selector
            Picker("Connection Mode", selection: $connectionTab) {
                Text("ESP32 Bridge").tag(0)
                Text("Direct Camera").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            if connectionTab == 0 {
                // ESP32 Mode
                if cameraManager.discoveredESP32s.isEmpty {
                    HStack {
                        if cameraManager.isScanning {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text(cameraManager.isScanning ? "Searching..." : "No ESP32s found")
                            .font(.system(size: 13))
                            .foregroundColor(.textSecondary)

                        Spacer()

                        Button {
                            cameraManager.refreshDiscovery()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 8)
                } else {
                    Text("Discovered:")
                        .font(.system(size: 11))
                        .foregroundColor(.textSecondary)

                    ForEach(cameraManager.discoveredESP32s) { esp in
                        let alreadyAdded = cameraManager.cameras.contains { $0.id == esp.id }

                        HStack {
                            Image(systemName: "wifi")
                                .font(.system(size: 12))
                            Text(esp.name)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(esp.ip)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.textSecondary)

                            if alreadyAdded {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.success)
                                    .font(.system(size: 14))
                            }
                        }
                        .padding(10)
                        .background(alreadyAdded ? Color.success.opacity(0.1) : Color.backgroundCard)
                        .cornerRadius(8)
                    }
                }

                Spacer()

                Divider().background(Color.backgroundCard)

                // Manual ESP32 IP entry
                HStack(spacing: 8) {
                    TextField("ESP32 IP Address", text: $manualIP)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(8)
                        .background(Color.backgroundCard)
                        .cornerRadius(6)

                    Button("Add") {
                        cameraManager.addESP32Manually(ip: manualIP)
                        manualIP = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accent)
                }
            } else {
                // Direct Camera Mode
                Text("Connect directly to Canon C200 Browser Remote")
                    .font(.system(size: 12))
                    .foregroundColor(.textSecondary)

                Spacer()

                Divider().background(Color.backgroundCard)

                // Camera IP entry
                HStack(spacing: 8) {
                    TextField("Camera IP Address", text: $directCameraIP)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(8)
                        .background(Color.backgroundCard)
                        .cornerRadius(6)

                    Button("Add") {
                        cameraManager.addDirectCamera(ip: directCameraIP)
                        directCameraIP = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accent)
                }

                Text("Default credentials: admin / admin")
                    .font(.system(size: 10))
                    .foregroundColor(.textSecondary)
            }
        }
        .padding(12)
        .frame(height: 340)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Camera Tile

struct CameraTile: View {
    let camera: Camera
    @ObservedObject var state: CameraState
    @EnvironmentObject var cameraManager: CameraManager
    @State private var isFlipped = false
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack {
            // Back of card (settings)
            TileBack(camera: camera, state: state, isFlipped: $isFlipped, showDeleteConfirm: $showDeleteConfirm)
                .environmentObject(cameraManager)
                .rotation3DEffect(.degrees(isFlipped ? 0 : 180), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)

            // Front of card (controls)
            TileFront(camera: camera, state: state, isFlipped: $isFlipped)
                .environmentObject(cameraManager)
                .rotation3DEffect(.degrees(isFlipped ? -180 : 0), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 0 : 1)
        }
        .frame(height: 340)
        .animation(.easeInOut(duration: 0.4), value: isFlipped)
        .alert("Remove Camera?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                cameraManager.removeCamera(camera)
            }
        } message: {
            Text("This will remove \(camera.name) from the dashboard.")
        }
    }
}

// MARK: - Tile Front (Camera Controls)

struct TileFront: View {
    let camera: Camera
    @ObservedObject var state: CameraState
    @Binding var isFlipped: Bool
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var presetManager: PresetManager
    @State private var isEditingName = false
    @State private var editedName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Camera header
            HStack {
                // Settings button (left)
                Button {
                    isFlipped = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundColor(.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                // Centered name and IP
                VStack(spacing: 2) {
                    if isEditingName {
                        TextField("Camera Name", text: $editedName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.textPrimary)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .focused($nameFieldFocused)
                            .onSubmit {
                                saveNameEdit()
                            }
                            .onExitCommand {
                                cancelNameEdit()
                            }
                    } else {
                        Text(camera.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.textPrimary)
                            .onTapGesture {
                                startNameEdit()
                            }
                    }

                    HStack(spacing: 4) {
                        Image(systemName: camera.connectionType == .esp32 ? "wifi" : "antenna.radiowaves.left.and.right")
                            .font(.system(size: 9))
                        Text(camera.ip)
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundColor(.textSecondary)
                }

                Spacer()

                // Recording indicator (right) or connecting spinner
                if state.isConnecting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16)
                } else if state.isRecording {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.error)
                            .frame(width: 8, height: 8)
                        Text("REC")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.error)
                    }
                } else {
                    // Invisible placeholder to keep layout balanced
                    Text("REC")
                        .font(.system(size: 11, weight: .bold))
                        .opacity(0)
                }
            }
            .padding(.horizontal, 4)

            // Fixed-height circles area (same for connected and disconnected)
            VStack(spacing: 8) {
                if state.isConnected {
                    // Row 1
                    HStack(spacing: 8) {
                        MetricCircle(state: state, cameraId: camera.id, controlType: .aperture,
                            label: "Av", value: state.aperture, icon: "camera.aperture",
                            color: .blue, progress: apertureProgress)
                        MetricCircle(state: state, cameraId: camera.id, controlType: .iso,
                            label: "ISO", value: state.iso, icon: "sun.max",
                            color: .orange, progress: isoProgress)
                        MetricCircle(state: state, cameraId: camera.id, controlType: .shutter,
                            label: "Tv", value: state.shutter, icon: "timer",
                            color: .purple, progress: shutterProgress)
                    }
                    // Row 2
                    HStack(spacing: 8) {
                        MetricCircle(state: state, cameraId: camera.id, controlType: .aeShift,
                            label: "AE", value: state.aeShift, icon: "plusminus",
                            color: .yellow, progress: 0.5)
                        MetricCircle(state: state, cameraId: camera.id, controlType: .whiteBalance,
                            label: "WB", value: state.wbKelvin, icon: "thermometer.sun",
                            color: wbColor, progress: wbProgress)
                        MetricCircle(state: state, cameraId: camera.id, controlType: .nd,
                            label: "ND", value: state.ndFilter, icon: "circle.lefthalf.filled",
                            color: .gray, progress: ndProgress)
                    }
                } else {
                    // Disconnected - placeholder circles with status overlay
                    ZStack {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                ForEach(0..<3, id: \.self) { _ in PlaceholderCircle() }
                            }
                            HStack(spacing: 8) {
                                ForEach(0..<3, id: \.self) { _ in PlaceholderCircle() }
                            }
                        }
                        VStack(spacing: 6) {
                            if camera.connectionType == .esp32 {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(state.esp32Reachable ? Color.green : Color.red)
                                        .frame(width: 6, height: 6)
                                    Text(state.esp32Reachable ? "ESP32 Online" : "ESP32 Offline")
                                        .font(.system(size: 11))
                                        .foregroundColor(.textSecondary)
                                }
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(state.isConnected ? Color.green : Color.red)
                                        .frame(width: 6, height: 6)
                                    Text(state.isConnected ? "Camera Online" : "Camera Disconnected")
                                        .font(.system(size: 11))
                                        .foregroundColor(.textSecondary)
                                }
                            } else {
                                Text("Not connected")
                                    .font(.system(size: 12))
                                    .foregroundColor(.textSecondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                    }
                }
            }
            .frame(height: 230)

            Divider().background(Color.backgroundCard)

            // Action button (REC or Connect)
            Button {
                if state.isConnected {
                    state.toggleRecord()
                } else {
                    state.stopAutoReconnect()
                    Task { await state.connect() }
                }
            } label: {
                HStack {
                    Image(systemName: state.isConnected ? (state.isRecording ? "stop.fill" : "record.circle") : "arrow.clockwise")
                        .font(.system(size: 12))
                    Text(state.isConnected ? (state.isRecording ? "STOP" : "REC") : "Connect")
                        .font(.system(size: 11, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(state.isConnected ? (state.isRecording ? Color.error : Color.backgroundCard) : Color.accent)
                .foregroundColor(state.isConnected ? (state.isRecording ? .white : .textPrimary) : .white)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(state.isRecording ? Color.error : Color.primary.opacity(0.1), lineWidth: state.isRecording ? 2 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tallyBorderColor, lineWidth: 4)
        )
        .animation(.easeInOut(duration: 0.2), value: state.isRecording)
        .animation(.easeInOut(duration: 0.15), value: state.tallyProgram)
        .animation(.easeInOut(duration: 0.15), value: state.tallyPreview)
    }

    // Tally border color
    private var tallyBorderColor: Color {
        if state.tallyProgram {
            return Color(red: 1.0, green: 0, blue: 0)  // Red
        } else if state.tallyPreview {
            return Color(red: 0, green: 1.0, blue: 0)  // Green
        }
        return .clear
    }

    // Progress calculations
    private var apertureProgress: Double {
        guard let value = Double(state.aperture.replacingOccurrences(of: "F", with: "")) else { return 0.5 }
        return 1.0 - ((value - 1.8) / (16 - 1.8))
    }

    private var isoProgress: Double {
        guard let value = Double(state.iso) else { return 0.5 }
        return (log2(value) - log2(160)) / (log2(25600) - log2(160))
    }

    private var shutterProgress: Double {
        return 0.5
    }

    private var wbProgress: Double {
        let kString = state.wbKelvin.replacingOccurrences(of: "K", with: "")
        guard let value = Double(kString) else { return 0.5 }
        return (value - 2000) / (15000 - 2000)
    }

    private var wbColor: Color {
        let kString = state.wbKelvin.replacingOccurrences(of: "K", with: "")
        guard let value = Double(kString) else { return .white }
        if value < 4000 { return .orange }
        if value < 5500 { return .yellow }
        return .cyan
    }

    private var ndProgress: Double {
        guard let value = Double(state.ndFilter) else { return 0 }
        return value / 10.0
    }

    // Name editing
    private func startNameEdit() {
        editedName = camera.name
        isEditingName = true
        nameFieldFocused = true
    }

    private func saveNameEdit() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != camera.name {
            cameraManager.renameCamera(camera, to: trimmed)
        }
        isEditingName = false
    }

    private func cancelNameEdit() {
        isEditingName = false
    }
}

// MARK: - Tile Back (Settings)

struct TileBack: View {
    let camera: Camera
    @ObservedObject var state: CameraState
    @Binding var isFlipped: Bool
    @Binding var showDeleteConfirm: Bool
    @EnvironmentObject var cameraManager: CameraManager

    var body: some View {
        VStack(spacing: 8) {
            // Header with back button
            HStack {
                Button {
                    isFlipped = false
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(camera.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                Spacer()

                // Invisible spacer for centering
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 11, weight: .medium))
                }
                .opacity(0)
            }

            Divider().background(Color.backgroundCard)

            // Camera Info - compact
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "IP", value: camera.ip)
                InfoRow(label: "Type", value: camera.connectionType == .esp32 ? "ESP32" : "Direct")

                if camera.connectionType == .esp32 {
                    InfoRow(label: "WiFi", value: state.wifiConnected ? "Connected" : "Disconnected")
                    InfoRow(label: "Eth", value: state.ethConnected ? "Connected" : "Disconnected")
                }
            }

            Divider().background(Color.backgroundCard)

            // TSL Tally section
            TileTallySection(camera: camera, state: state)
                .environmentObject(cameraManager)

            Spacer(minLength: 4)

            // Remove camera button
            Button {
                showDeleteConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Remove")
                }
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.error.opacity(0.15))
                .foregroundColor(.error)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Tile Tally Section

struct TileTallySection: View {
    let camera: Camera
    @ObservedObject var state: CameraState
    @EnvironmentObject var cameraManager: CameraManager
    @State private var showingIndexPicker = false

    private var tslIndices: [Int] {
        cameraManager.cameras.first { $0.id == camera.id }?.tslIndices ?? []
    }

    private var assignmentLabel: String {
        if tslIndices.isEmpty { return "None" }
        let sorted = tslIndices.sorted()
        if sorted.count <= 4 { return sorted.map(String.init).joined(separator: ", ") }
        return sorted.prefix(3).map(String.init).joined(separator: ", ") + " +\(sorted.count - 3)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row: label + live tally dots
            HStack {
                Text("TALLY")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.textSecondary)
                    .tracking(1)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(state.tallyProgram ? Color.error : Color(white: 0.25))
                        .frame(width: 9, height: 9)
                    Circle()
                        .fill(state.tallyPreview ? Color.success : Color(white: 0.25))
                        .frame(width: 9, height: 9)
                }
            }

            // TSL input assignment
            if camera.connectionType == .esp32 {
                HStack(spacing: 6) {
                    Text("Inputs:")
                        .font(.system(size: 10))
                        .foregroundColor(.textSecondary)

                    Button {
                        showingIndexPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(assignmentLabel)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(tslIndices.isEmpty ? .textSecondary : .textPrimary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                                .foregroundColor(.textSecondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.backgroundCard)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingIndexPicker, arrowEdge: .bottom) {
                        TSLIndexPicker(selectedIndices: Binding(
                            get: { tslIndices },
                            set: { newIndices in
                                if let idx = cameraManager.cameras.firstIndex(where: { $0.id == camera.id }) {
                                    cameraManager.cameras[idx].tslIndices = newIndices
                                    cameraManager.saveCameras()
                                }
                            }
                        ))
                    }

                    Spacer()

                    // Debug buttons
                    HStack(spacing: 4) {
                        Button { Task { await state.updateTallyState(program: true, preview: false) } } label: {
                            Text("PGM").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(Color.error).cornerRadius(3)
                        }
                        .buttonStyle(.plain).help("Force program tally")

                        Button { Task { await state.updateTallyState(program: false, preview: true) } } label: {
                            Text("PVW").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(Color.success).cornerRadius(3)
                        }
                        .buttonStyle(.plain).help("Force preview tally")

                        Button { Task { await state.updateTallyState(program: false, preview: false) } } label: {
                            Text("OFF").font(.system(size: 9, weight: .semibold)).foregroundColor(.textSecondary)
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(Color.backgroundCard).cornerRadius(3)
                        }
                        .buttonStyle(.plain).help("Clear tally")
                    }
                }
            }
        }
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.textPrimary)
                .lineLimit(1)
        }
    }
}

// MARK: - Placeholder Circle (matches MetricCircle dimensions)

struct PlaceholderCircle: View {
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .stroke(Color.gray.opacity(0.15), lineWidth: 4)
                .frame(width: 64, height: 64)
            Text("--")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.textSecondary.opacity(0.3))
            Text("--")
                .font(.system(size: 13))
                .foregroundColor(.textSecondary.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Metric Circle with Popover

struct MetricCircle: View {
    @ObservedObject var state: CameraState
    @EnvironmentObject var presetManager: PresetManager
    let cameraId: String
    let controlType: ControlType
    let label: String
    let value: String
    let icon: String
    let color: Color
    let progress: Double

    @State private var showPopover = false
    @State private var showCapturedFeedback = false

    private var presetSettingType: PresetSettingType? {
        switch controlType {
        case .aperture: return .aperture
        case .iso: return .iso
        case .shutter: return .shutter
        case .aeShift: return .aeShift
        case .whiteBalance: return .wbKelvin
        case .nd: return .ndFilter
        case .focus: return nil
        }
    }

    private var isIncludedInPreset: Bool {
        guard let settingType = presetSettingType else { return false }
        return presetManager.isSettingIncluded(settingType, cameraId: cameraId)
    }

    private var savedPresetValue: String? {
        guard let settingType = presetSettingType else { return nil }
        return presetManager.savedValue(settingType, cameraId: cameraId)
    }

    private var effectiveOpacity: Double {
        if presetManager.isEditingPreset {
            return isIncludedInPreset ? 1.0 : 0.3
        }
        return 1.0
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Background fill for tap target
                Circle()
                    .fill(Color.clear)

                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 4)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: progress)

                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(color)

                // Show checkmark when included in preset edit mode
                if presetManager.isEditingPreset && isIncludedInPreset {
                    Circle()
                        .fill(Color.green.opacity(0.9))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                        )
                        .offset(x: 24, y: -24)
                }

                // Flash feedback when value is captured
                if showCapturedFeedback {
                    Circle()
                        .fill(Color.green.opacity(0.5))
                        .transition(.opacity)
                }
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())

            // In edit mode with a saved value, show the saved target value
            if presetManager.isEditingPreset, let saved = savedPresetValue {
                Text(saved)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .opacity(effectiveOpacity)
        .scaleEffect(showCapturedFeedback ? 1.1 : 1.0)
        .gesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    // Long press captures current value
                    if presetManager.isEditingPreset, let settingType = presetSettingType {
                        appLog("Long press: capturing \(settingType.rawValue)='\(value)' for camera \(cameraId)")
                        presetManager.captureSettingValue(settingType, cameraId: cameraId, currentValue: value)
                        // Show feedback
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showCapturedFeedback = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showCapturedFeedback = false
                            }
                        }
                    }
                }
        )
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    if presetManager.isEditingPreset {
                        if let settingType = presetSettingType {
                            presetManager.toggleSetting(settingType, cameraId: cameraId, currentValue: value)
                        }
                    } else {
                        showPopover = true
                    }
                }
        )
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ControlPopover(control: controlType, state: state)
        }
        .animation(.easeInOut(duration: 0.2), value: presetManager.isEditingPreset)
        .animation(.easeInOut(duration: 0.2), value: isIncludedInPreset)
        .animation(.easeInOut(duration: 0.15), value: showCapturedFeedback)
    }
}

// MARK: - Control Types

enum ControlType: Identifiable {
    case aperture, iso, shutter, aeShift, whiteBalance, nd, focus

    var id: String {
        switch self {
        case .aperture: return "aperture"
        case .iso: return "iso"
        case .shutter: return "shutter"
        case .aeShift: return "aeShift"
        case .whiteBalance: return "whiteBalance"
        case .nd: return "nd"
        case .focus: return "focus"
        }
    }

    var title: String {
        switch self {
        case .aperture: return "Aperture"
        case .iso: return "ISO"
        case .shutter: return "Shutter"
        case .aeShift: return "AE Shift"
        case .whiteBalance: return "White Balance"
        case .nd: return "ND Filter"
        case .focus: return "Focus"
        }
    }
}

// MARK: - Control Popover

struct ControlPopover: View {
    let control: ControlType
    @ObservedObject var state: CameraState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(control.title)
                .font(.system(size: 14, weight: .semibold))

            Text(currentValue)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(.accent)

            switch control {
            case .aperture:
                AdjustmentButtons(state: state,
                    onMinus: { state.sendCommand("iris", "plus") },
                    onPlus: { state.sendCommand("iris", "minus") }
                )
            case .iso:
                AdjustmentButtons(state: state,
                    onMinus: { state.sendCommand("iso", "minus") },
                    onPlus: { state.sendCommand("iso", "plus") }
                )
            case .shutter:
                AdjustmentButtons(state: state,
                    onMinus: { state.sendCommand("shutter", "minus") },
                    onPlus: { state.sendCommand("shutter", "plus") }
                )
            case .aeShift:
                AdjustmentButtons(state: state,
                    onMinus: { state.sendCommand("aes", "minus") },
                    onPlus: { state.sendCommand("aes", "plus") }
                )
            case .whiteBalance:
                WhiteBalanceControls(state: state)
            case .nd:
                AdjustmentButtons(state: state,
                    onMinus: { state.sendCommand("nd", "minus") },
                    onPlus: { state.sendCommand("nd", "plus") }
                )
            case .focus:
                FocusControls(state: state)
            }
        }
        .padding(20)
        .frame(minWidth: 200)
    }

    private var currentValue: String {
        switch control {
        case .aperture: return state.aperture
        case .iso: return state.iso
        case .shutter: return state.shutter
        case .aeShift: return state.aeShift
        case .whiteBalance: return state.wbKelvin
        case .nd: return state.ndFilter
        case .focus: return state.afMode
        }
    }
}

// MARK: - Adjustment Buttons

struct AdjustmentButtons: View {
    @ObservedObject var state: CameraState
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            Button(action: onMinus) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(state.isCommandPending ? .gray : .accent)
            }
            .buttonStyle(.plain)
            .disabled(state.isCommandPending)

            if state.isCommandPending {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 20, height: 20)
            }

            Button(action: onPlus) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(state.isCommandPending ? .gray : .accent)
            }
            .buttonStyle(.plain)
            .disabled(state.isCommandPending)
        }
    }
}

// MARK: - White Balance Controls

struct WhiteBalanceControls: View {
    @ObservedObject var state: CameraState

    var body: some View {
        VStack(spacing: 12) {
            Text("Mode: \(state.wbMode)")
                .font(.system(size: 12))
                .foregroundColor(.textSecondary)

            AdjustmentButtons(state: state,
                onMinus: { state.sendCommand("wbk", "minus") },
                onPlus: { state.sendCommand("wbk", "plus") }
            )

            Divider()

            HStack(spacing: 8) {
                WBPresetButton(label: "AWB", mode: "awb", state: state)
                WBPresetButton(label: "☀️", mode: "daylight", state: state)
                WBPresetButton(label: "💡", mode: "tungsten", state: state)
            }

            HStack(spacing: 8) {
                WBPresetButton(label: "User 1", mode: "user1", state: state)
                WBPresetButton(label: "Set A", mode: "seta", state: state)
                WBPresetButton(label: "Set B", mode: "setb", state: state)
            }
        }
    }
}

struct WBPresetButton: View {
    let label: String
    let mode: String
    @ObservedObject var state: CameraState

    var body: some View {
        Button {
            state.setWhiteBalance(mode)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(state.wbMode == mode ? Color.accent : Color.backgroundCard)
                .foregroundColor(state.wbMode == mode ? .white : .textPrimary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Focus Controls

struct FocusControls: View {
    @ObservedObject var state: CameraState

    var body: some View {
        VStack(spacing: 12) {
            Text("Mode: \(state.afMode)")
                .font(.system(size: 12))
                .foregroundColor(.textSecondary)

            Button {
                state.sendFocus("oneshot")
            } label: {
                HStack {
                    Image(systemName: "scope")
                    Text("One-Shot AF")
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.accent)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            HStack(spacing: 16) {
                Button {
                    state.sendFocus("near1")
                } label: {
                    VStack {
                        Image(systemName: "arrow.left")
                        Text("Near")
                            .font(.system(size: 10))
                    }
                    .frame(width: 50, height: 50)
                    .background(Color.backgroundCard)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button {
                    state.sendFocus("far1")
                } label: {
                    VStack {
                        Image(systemName: "arrow.right")
                        Text("Far")
                            .font(.system(size: 10))
                    }
                    .frame(width: 50, height: 50)
                    .background(Color.backgroundCard)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Colors

extension Color {
    static let backgroundPrimary = Color(red: 0.08, green: 0.08, blue: 0.12)
    static let backgroundSecondary = Color(red: 0.12, green: 0.12, blue: 0.16)
    static let backgroundCard = Color(red: 0.16, green: 0.16, blue: 0.20)
    static let accent = Color(red: 0.914, green: 0.271, blue: 0.376)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.6)
    static let success = Color(red: 0.290, green: 0.871, blue: 0.502)
    static let warning = Color(red: 0.984, green: 0.749, blue: 0.141)
    static let error = Color(red: 0.937, green: 0.267, blue: 0.267)
}

#Preview {
    ContentView()
        .environmentObject(CameraManager())
        .environmentObject(PresetManager())
}
