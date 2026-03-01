import SwiftUI

struct FirmwareUpdateView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @Environment(\.dismiss) var dismiss
    @StateObject private var manager = FirmwareUpdateManager()

    @State private var showingConfirmation = false
    @State private var selectedIDs: Set<String> = []

    private var esp32Cameras: [Camera] {
        cameraManager.cameras.filter { $0.connectionType == .esp32 }
    }

    private var selectedCameras: [Camera] {
        esp32Cameras.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Firmware Update")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .disabled(manager.isUpdating)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Firmware file section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FIRMWARE FILE")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .tracking(1)

                        HStack {
                            if let path = manager.firmwarePath {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(path.lastPathComponent)
                                        .font(.system(size: 13, design: .monospaced))
                                    if let version = manager.availableFirmwareVersion {
                                        Text("Version \(version)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Text(fileSize(path))
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            } else {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("No firmware found — build firmware first")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }

                            Button("Browse...") {
                                browseForFirmware()
                            }
                            .disabled(manager.isUpdating)
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }

                    // Cameras section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ESP32 BOARDS (\(esp32Cameras.count))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .tracking(1)

                        if esp32Cameras.isEmpty {
                            Text("No ESP32 cameras added. Add cameras using the main window.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding(10)
                        } else {
                            VStack(spacing: 1) {
                                ForEach(esp32Cameras) { camera in
                                    BoardRow(
                                        camera: camera,
                                        status: manager.boardStatuses[camera.id] ?? .idle,
                                        currentVersion: manager.boardVersions[camera.id] ?? "--",
                                        isSelected: selectedIDs.contains(camera.id),
                                        onToggle: {
                                            if selectedIDs.contains(camera.id) {
                                                selectedIDs.remove(camera.id)
                                            } else {
                                                selectedIDs.insert(camera.id)
                                            }
                                        }
                                    )
                                }
                            }
                            .cornerRadius(8)
                        }
                    }

                    // Instructions
                    if !manager.isUpdating && esp32Cameras.allSatisfy({ (manager.boardStatuses[$0.id] ?? .idle) == .idle }) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("WHAT HAPPENS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                                .tracking(1)
                            Text("Selected boards will download and flash the new firmware simultaneously over WiFi. Each board will reboot automatically (~15–20 seconds). Cameras will briefly go offline during the update.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                // Board version summary
                if !manager.isUpdating {
                    let doneCount = esp32Cameras.filter {
                        if case .done = manager.boardStatuses[$0.id] ?? .idle { return true }
                        return false
                    }.count
                    if doneCount > 0 {
                        Text("\(doneCount) of \(esp32Cameras.count) updated successfully")
                            .font(.system(size: 13))
                            .foregroundColor(.green)
                    }
                }

                Spacer()

                Button("Start Update") {
                    showingConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.firmwarePath == nil || selectedCameras.isEmpty || manager.isUpdating)
            }
            .padding()
        }
        .frame(width: 500, height: 480)
        .onAppear {
            selectedIDs = Set(esp32Cameras.map { $0.id })
            Task { await manager.fetchBoardVersions(cameras: esp32Cameras) }
        }
        .confirmationDialog(
            "Update Firmware on \(selectedCameras.count) Board\(selectedCameras.count == 1 ? "" : "s")?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Update") {
                Task {
                    await manager.startUpdate(cameras: selectedCameras)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Selected boards will download and flash the new firmware. Cameras will be briefly offline during the update.")
        }
    }

    private func fileSize(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return "" }
        let kb = Double(size) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    private func browseForFirmware() {
        let panel = NSOpenPanel()
        panel.title = "Select Firmware Binary"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Select the c200_bridge.bin firmware file"
        if panel.runModal() == .OK, let url = panel.url {
            manager.firmwarePath = url
        }
    }
}

// MARK: - Board row

struct BoardRow: View {
    let camera: Camera
    let status: FirmwareUpdateManager.BoardStatus
    let currentVersion: String
    var isSelected: Bool = true
    var onToggle: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 20)
                .onTapGesture {
                    if case .idle = status { onToggle?() }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) {
                    Text(camera.ip)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("running \(currentVersion)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(status.displayText)
                .font(.system(size: 12))
                .foregroundColor(statusColor)

            if status.isInProgress {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .idle:
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
        case .starting, .downloading, .flashing, .rebooting:
            Image(systemName: "arrow.up.circle")
                .foregroundColor(.blue)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    private var statusColor: Color {
        switch status {
        case .idle:    return .secondary
        case .error:   return .red
        case .done:    return .green
        default:       return .blue
        }
    }
}
