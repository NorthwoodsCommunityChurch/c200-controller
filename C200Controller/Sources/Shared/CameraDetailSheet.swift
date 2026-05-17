import SwiftUI

/// Sheet shown when a camera card is tapped on its name area or ⋯ button.
/// Provides identify, TSL index, camera positions, and remove. Mirrors the
/// macOS card-flip back side, restructured as an iOS Form.
struct CameraDetailSheet: View {
    let cameraId: String
    @EnvironmentObject var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    @State private var showingRemoveConfirm = false
    @State private var identifyCountdown = 0
    @State private var identifyTask: Task<Void, Never>?

    private var camera: Camera? {
        cameraManager.cameras.first { $0.id == cameraId }
    }
    private var state: CameraState? {
        cameraManager.cameraStates[cameraId]
    }

    var body: some View {
        NavigationStack {
            Form {
                if let camera, let state {
                    Section("Status") {
                        statusRow(camera: camera, state: state)
                        if camera.connectionType == .esp32 {
                            LabeledContent("WiFi") {
                                statusDot(state.wifiConnected) + Text(state.wifiConnected ? "OK" : "—").foregroundColor(.secondary)
                            }
                            LabeledContent("Ethernet") {
                                statusDot(state.ethConnected) + Text(state.ethConnected ? "OK" : "—").foregroundColor(.secondary)
                            }
                        }
                        LabeledContent("IP", value: camera.ip)
                            .font(.body.monospaced())
                    }

                    if camera.connectionType == .esp32 {
                        Section("TSL Tally") {
                            tslPicker(camera: camera)
                            tallyTestButtons(state: state)
                        }

                        Section("Camera Positions") {
                            positionsPicker(camera: camera)
                        }

                        Section {
                            identifyButton(state: state)
                        } footer: {
                            Text("Flashes the red + green LEDs for 5 seconds so you can visually find the physical bridge.")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            showingRemoveConfirm = true
                        } label: {
                            Label("Remove camera", systemImage: "trash")
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Camera removed")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .navigationTitle(camera?.name ?? "Camera")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .alert("Remove camera?", isPresented: $showingRemoveConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Remove", role: .destructive) {
                    if let camera {
                        cameraManager.removeCamera(camera)
                    }
                    dismiss()
                }
            } message: {
                Text("This will remove \(camera?.name ?? "the camera") from the dashboard.")
            }
            .onDisappear { identifyTask?.cancel() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Rows

    private func statusRow(camera: Camera, state: CameraState) -> some View {
        HStack {
            statusDot(state.isConnected)
            Text(state.isConnected ? "Connected" : (state.isConnecting ? "Connecting…" : "Offline"))
                .foregroundStyle(state.isConnected ? Theme.green : Theme.label2)
            Spacer()
            if state.isRecording {
                Label("REC", systemImage: "record.circle")
                    .foregroundStyle(Theme.red)
                    .font(.callout.bold())
            }
        }
    }

    private func statusDot(_ on: Bool) -> Text {
        Text(Image(systemName: "circle.fill"))
            .foregroundColor(on ? Theme.green : Theme.label3) + Text(" ")
    }

    // MARK: - TSL

    private func tslPicker(camera: Camera) -> some View {
        Picker(selection: Binding(
            get: { camera.tslIndex },
            set: { newValue in
                cameraManager.setTslIndex(for: camera.id, index: newValue)
            }
        )) {
            Text("None").tag(0)
            ForEach(1...32, id: \.self) { n in
                Text("TSL \(n)").tag(n)
            }
        } label: {
            Label("Input", systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    private func tallyTestButtons(state: CameraState) -> some View {
        HStack(spacing: 8) {
            Text("Test:")
                .font(.callout)
                .foregroundStyle(.secondary)
            tallyTestButton("PGM", color: Theme.red) {
                state.updateTallyState(program: true, preview: false)
            }
            tallyTestButton("PVW", color: Theme.green) {
                state.updateTallyState(program: false, preview: true)
            }
            tallyTestButton("OFF", color: Theme.label3) {
                state.updateTallyState(program: false, preview: false)
            }
        }
    }

    private func tallyTestButton(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(color, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Positions

    private func positionsPicker(camera: Camera) -> some View {
        Picker(selection: Binding<Int?>(
            get: { camera.positionsNumber },
            set: { newValue in
                if let idx = cameraManager.cameras.firstIndex(where: { $0.id == camera.id }) {
                    cameraManager.cameras[idx].positionsNumber = newValue
                    cameraManager.saveCameras()
                    cameraManager.pushPositionsToESP32(camera: cameraManager.cameras[idx])
                }
            }
        )) {
            Text("None").tag(Int?.none)
            ForEach(1...8, id: \.self) { n in
                Text("Cam \(n)").tag(Int?.some(n))
            }
        } label: {
            Label("Camera #", systemImage: "video.bubble")
        }
    }

    // MARK: - Identify

    private func identifyButton(state: CameraState) -> some View {
        Button {
            guard identifyCountdown == 0 else { return }
            identifyCountdown = 5
            Task { await state.sendIdentify() }
            identifyTask = Task { @MainActor in
                for _ in 0..<5 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    if identifyCountdown > 0 { identifyCountdown -= 1 }
                }
            }
        } label: {
            Label(identifyCountdown > 0 ? "Identifying… \(identifyCountdown)s" : "Identify",
                  systemImage: identifyCountdown > 0 ? "circle.dashed" : "lightbulb")
        }
        .disabled(identifyCountdown > 0)
    }
}
