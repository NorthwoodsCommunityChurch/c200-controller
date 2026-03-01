import SwiftUI

struct TallySettingsView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @Environment(\.dismiss) var dismiss

    @State private var searchText = ""
    @State private var portText = ""
    @State private var brightness: Double = Double(UserDefaults.standard.integer(forKey: "tally_brightness") == 0 ? 1 : UserDefaults.standard.integer(forKey: "tally_brightness"))
    @State private var brightnessDebounce: DispatchWorkItem?

    var filteredCameras: [Camera] {
        if searchText.isEmpty {
            return cameraManager.cameras
        }
        return cameraManager.cameras.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Tally Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            // TSL Connection Status
            VStack(spacing: 12) {
                HStack {
                    // Three-state indicator
                    Circle()
                        .fill(tslStatusColor)
                        .frame(width: 8, height: 8)
                    Text("TSL")
                        .font(.caption)
                    Text(tslStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Toggle("Enable TSL", isOn: Binding(
                        get: { cameraManager.tslEnabled },
                        set: { enabled in
                            if enabled { cameraManager.startTSL() }
                            else { cameraManager.stopTSL() }
                        }
                    ))
                }

                HStack {
                    Text("TCP Port:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.center)
                        .onChange(of: portText) { newValue in
                            updatePort(newValue)
                        }
                    Spacer()
                }

                HStack(spacing: 10) {
                    Text("LED Brightness:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Slider(value: $brightness, in: 1...100, step: 1)
                        .onChange(of: brightness) { newValue in
                            UserDefaults.standard.set(Int(newValue), forKey: "tally_brightness")
                            brightnessDebounce?.cancel()
                            let work = DispatchWorkItem { updateBrightness(Int(newValue)) }
                            brightnessDebounce = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                        }
                    Text("\(Int(brightness))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search cameras...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding()

            // Column headers
            HStack {
                Text("Camera")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Debug")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                    .frame(width: 16)
                Text("TSL Inputs")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                    .frame(width: 28)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            // Camera list
            List {
                ForEach(filteredCameras) { camera in
                    CameraTallyRow(camera: camera, cameraManager: cameraManager)
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 560, height: 620)
        .onAppear {
            portText = String(cameraManager.tslPort)
        }
    }

    private var tslStatusColor: Color {
        if cameraManager.tslClientConnected { return .green }
        if cameraManager.tslListening { return .yellow }
        return .gray
    }

    private var tslStatusText: String {
        if cameraManager.tslClientConnected { return "Switcher connected" }
        if cameraManager.tslListening { return "Listening on port \(cameraManager.tslPort)..." }
        return "Off"
    }

    private func updateBrightness(_ percent: Int) {
        let esp32Value = Int(Double(percent) / 100.0 * 255.0)
        for camera in cameraManager.cameras where camera.connectionType == .esp32 {
            if let state = cameraManager.cameraStates[camera.id] {
                Task { await state.sendBrightness(esp32Value) }
            }
        }
    }

    private func updatePort(_ value: String) {
        guard let port = UInt16(value), port > 0, port <= 65535 else { return }
        guard port != cameraManager.tslPort else { return }  // no-op if port unchanged

        let wasEnabled = cameraManager.tslEnabled
        if wasEnabled { cameraManager.stopTSL() }
        cameraManager.tslPort = port
        UserDefaults.standard.set(Int(port), forKey: "tsl_port")
        if wasEnabled {
            cameraManager.startTSL()
            appLog("TSL listener restarted on port \(port)")
        } else {
            appLog("TSL port changed to \(port)")
        }
    }
}

// MARK: - Camera Row

struct CameraTallyRow: View {
    let camera: Camera
    let cameraManager: CameraManager

    @State private var showingPicker = false

    var selectedIndices: [Int] {
        cameraManager.cameras.first { $0.id == camera.id }?.tslIndices ?? []
    }

    var assignmentLabel: String {
        if selectedIndices.isEmpty { return "None" }
        let sorted = selectedIndices.sorted()
        if sorted.count <= 4 {
            return sorted.map(String.init).joined(separator: ", ")
        }
        return sorted.prefix(3).map(String.init).joined(separator: ", ") + " +\(sorted.count - 3)"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Camera name + IP
            VStack(alignment: .leading, spacing: 2) {
                Text(camera.name)
                    .font(.headline)
                Text(camera.ip)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer()

            // Debug buttons
            HStack(spacing: 5) {
                Button(action: { sendDebugTally(program: true, preview: false) }) {
                    Text("PGM")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.red)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Set program (red) tally on this camera's ESP32")

                Button(action: { sendDebugTally(program: false, preview: true) }) {
                    Text("PVW")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.green)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Set preview (green) tally on this camera's ESP32")

                Button(action: { sendDebugTally(program: false, preview: false) }) {
                    Text("OFF")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlColor))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Clear tally on this camera's ESP32")
            }

            // TSL input picker button
            Button(action: { showingPicker = true }) {
                HStack(spacing: 5) {
                    Text(assignmentLabel)
                        .font(.caption)
                        .foregroundColor(selectedIndices.isEmpty ? .secondary : .primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(minWidth: 90)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPicker, arrowEdge: .trailing) {
                TSLIndexPicker(selectedIndices: Binding(
                    get: { selectedIndices },
                    set: { newIndices in
                        if let idx = cameraManager.cameras.firstIndex(where: { $0.id == camera.id }) {
                            cameraManager.cameras[idx].tslIndices = newIndices
                            cameraManager.saveCameras()
                            appLog("Updated TSL indices for \(camera.name): \(newIndices.sorted())")
                        }
                    }
                ))
            }

            // Live tally indicators
            HStack(spacing: 4) {
                if let state = cameraManager.cameraStates[camera.id] {
                    Circle()
                        .fill(state.tallyProgram ? Color.red : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(state.tallyPreview ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                } else {
                    Circle().fill(Color.gray.opacity(0.2)).frame(width: 10, height: 10)
                    Circle().fill(Color.gray.opacity(0.2)).frame(width: 10, height: 10)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func sendDebugTally(program: Bool, preview: Bool) {
        guard let state = cameraManager.cameraStates[camera.id] else {
            appLog("Debug tally: no state for \(camera.name)")
            return
        }
        let label = program ? "PROGRAM" : (preview ? "PREVIEW" : "OFF")
        appLog("Debug tally \(label) → \(camera.name)")
        Task {
            await state.updateTallyState(program: program, preview: preview)
        }
    }
}

// MARK: - TSL Index Picker Popover

struct TSLIndexPicker: View {
    @Binding var selectedIndices: [Int]
    @State private var search = ""

    var filteredIndices: [Int] {
        let all = Array(1...127)
        if search.isEmpty { return all }
        return all.filter { String($0).contains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("Search inputs...", text: $search)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)

            Divider()

            // Index list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredIndices, id: \.self) { index in
                        Button(action: { toggleIndex(index) }) {
                            HStack(spacing: 10) {
                                Image(systemName: selectedIndices.contains(index) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedIndices.contains(index) ? .accentColor : Color(NSColor.tertiaryLabelColor))
                                    .font(.system(size: 15))
                                Text("Input \(index)")
                                    .foregroundColor(.primary)
                                    .font(.callout)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selectedIndices.contains(index) ? Color.accentColor.opacity(0.08) : Color.clear)
                        }
                        .buttonStyle(.plain)

                        if index != filteredIndices.last {
                            Divider()
                                .padding(.leading, 38)
                        }
                    }
                }
            }

            // Footer: selected count + clear
            if !selectedIndices.isEmpty {
                Divider()
                HStack {
                    Text("\(selectedIndices.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Clear All") {
                        selectedIndices = []
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .frame(width: 210, height: 320)
    }

    private func toggleIndex(_ index: Int) {
        if let pos = selectedIndices.firstIndex(of: index) {
            selectedIndices.remove(at: pos)
        } else {
            selectedIndices.append(index)
        }
    }
}

#Preview {
    TallySettingsView()
        .environmentObject(CameraManager())
}
