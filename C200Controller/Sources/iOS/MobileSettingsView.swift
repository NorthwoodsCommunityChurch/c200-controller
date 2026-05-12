import SwiftUI

/// Phase 3 — iPad settings: TSL config + LED brightness + camera positions
/// integration. Mirrors macOS TallySettingsView + CameraPositionsSettingsView
/// in a Form-based iOS layout.
struct MobileSettingsView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @State private var portText: String = ""
    @State private var brightness: Double = 1
    @State private var brightnessDebounce: Task<Void, Never>?
    @State private var positionsHostDraft: String = ""
    @State private var positionsPortDraft: String = ""
    @State private var showingFirmwareUpdate = false

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            Form {
                tslSection
                positionsSection
                firmwareSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { syncLocalState() }
        .sheet(isPresented: $showingFirmwareUpdate) {
            FirmwareUpdateSheet()
                .environmentObject(cameraManager)
        }
    }

    // MARK: - TSL

    private var tslSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { cameraManager.tslEnabled },
                set: { enabled in
                    if enabled { cameraManager.startTSL() } else { cameraManager.stopTSL() }
                }
            )) {
                Label("TSL Listener", systemImage: "antenna.radiowaves.left.and.right")
            }

            HStack {
                Label {
                    Text("Status")
                } icon: {
                    Circle()
                        .fill(tslStatusColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: tslStatusColor.opacity(0.6), radius: 3)
                }
                Spacer()
                Text(tslStatusText)
                    .foregroundStyle(.secondary)
                    .font(.callout)
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

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("LED Brightness")
                    Spacer()
                    Text("\(Int(brightness))%")
                        .foregroundStyle(.secondary)
                        .font(.body.monospaced())
                        .frame(width: 50, alignment: .trailing)
                }
                Slider(value: $brightness, in: 1...100, step: 1)
                    .tint(Theme.accent)
                    .onChange(of: brightness) { _, new in
                        UserDefaults.standard.set(Int(new), forKey: "tally_brightness")
                        brightnessDebounce?.cancel()
                        brightnessDebounce = Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            if Task.isCancelled { return }
                            pushBrightnessToAll(Int(new))
                        }
                    }
            }

            Toggle(isOn: $cameraManager.tslSwapProgramPreview) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Swap Program / Preview")
                    Text("For switchers that invert T1/T2 (Ross Ultrix, Roland)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("TSL Tally")
        } footer: {
            Text("Each ESP32 board listens on the configured TSL port and self-tallies based on its assigned TSL index. The iPad listens too, mainly to display state.")
        }
    }

    // MARK: - Positions

    private var positionsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { cameraManager.positionsEnabled },
                set: { enabled in
                    if enabled {
                        cameraManager.positionsHost = positionsHostDraft
                        if let p = Int(positionsPortDraft) { cameraManager.positionsPort = p }
                        cameraManager.startPositions()
                    } else {
                        cameraManager.stopPositions()
                    }
                }
            )) {
                Label("Camera Positions polling", systemImage: "video.bubble")
            }

            HStack {
                Text("Host")
                Spacer()
                TextField("camera-positions.local", text: $positionsHostDraft)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospaced())
                    .onSubmit { commitPositionsConfig() }
            }
            HStack {
                Text("Port")
                Spacer()
                TextField("8765", text: $positionsPortDraft)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .font(.body.monospaced())
                    .onSubmit { commitPositionsConfig() }
            }

            if !cameraManager.positionsAssignments.isEmpty {
                ForEach(cameraManager.positionsAssignments.keys.sorted(), id: \.self) { number in
                    if let assignment = cameraManager.positionsAssignments[number] {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Cam \(number)")
                                    .font(.body.weight(.medium))
                                Spacer()
                                Text(assignment.operatorName ?? "—")
                                    .foregroundStyle(.secondary)
                            }
                            if !assignment.lenses.isEmpty {
                                Text(assignment.lenses.joined(separator: " · "))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.label3)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        } header: {
            Text("Camera Positions")
        } footer: {
            Text("Pulls operator + lens assignments from the Camera Positions app and pushes them to each board's OLED display.")
        }
    }

    // MARK: - Firmware

    private var firmwareSection: some View {
        Section("Firmware") {
            Button {
                showingFirmwareUpdate = true
            } label: {
                Label("Push firmware to boards…", systemImage: "arrow.up.circle")
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            let bundle = Bundle.main
            LabeledContent("App version",
                           value: "\(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
            LabeledContent("Cameras", value: "\(cameraManager.cameras.count)")
            LabeledContent("Bundle ID",
                           value: bundle.bundleIdentifier ?? "—")
                .font(.caption.monospaced())
        }
    }

    // MARK: - Helpers

    private func syncLocalState() {
        portText = String(cameraManager.tslPort)
        positionsHostDraft = cameraManager.positionsHost
        positionsPortDraft = String(cameraManager.positionsPort)
        let saved = UserDefaults.standard.integer(forKey: "tally_brightness")
        brightness = Double(saved == 0 ? 1 : saved)
    }

    private func commitPort() {
        guard let port = UInt16(portText), port > 0 else {
            portText = String(cameraManager.tslPort)
            return
        }
        guard port != cameraManager.tslPort else { return }
        let wasEnabled = cameraManager.tslEnabled
        if wasEnabled { cameraManager.stopTSL() }
        cameraManager.tslPort = port
        if wasEnabled { cameraManager.startTSL() }
    }

    private func commitPositionsConfig() {
        cameraManager.positionsHost = positionsHostDraft
        if let p = Int(positionsPortDraft) {
            cameraManager.positionsPort = p
        }
        UserDefaults.standard.set(positionsHostDraft, forKey: "positions_host")
        UserDefaults.standard.set(cameraManager.positionsPort, forKey: "positions_port")
        if cameraManager.positionsEnabled {
            cameraManager.stopPositions()
            cameraManager.startPositions()
        }
    }

    private func pushBrightnessToAll(_ percent: Int) {
        let esp32Value = Int(Double(percent) / 100.0 * 255.0)
        for camera in cameraManager.cameras where camera.connectionType == .esp32 {
            if let state = cameraManager.cameraStates[camera.id] {
                Task { await state.sendBrightness(esp32Value) }
            }
        }
    }

    private var tslStatusColor: Color {
        if cameraManager.tslClientConnected { return Theme.green }
        if cameraManager.tslListening { return Theme.yellow }
        return Theme.label3
    }
    private var tslStatusText: String {
        if cameraManager.tslClientConnected { return "Switcher connected" }
        if cameraManager.tslListening { return "Listening on :\(cameraManager.tslPort)" }
        return "Off"
    }
}
