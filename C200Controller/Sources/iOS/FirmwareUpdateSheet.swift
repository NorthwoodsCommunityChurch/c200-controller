import SwiftUI

struct FirmwareUpdateSheet: View {
    @EnvironmentObject var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var firmware = FirmwareUpdateManager()
    @State private var selectedCameraIds: Set<String> = []

    private var esp32Cameras: [Camera] {
        cameraManager.cameras.filter { $0.connectionType == .esp32 }
    }

    private var canStart: Bool {
        !selectedCameraIds.isEmpty && firmware.firmwarePath != nil && !firmware.isUpdating
    }

    var body: some View {
        NavigationStack {
            Form {
                bundledSection
                boardsSection
                if firmware.isUpdating || !firmware.boardStatuses.isEmpty {
                    statusSection
                }
            }
            .navigationTitle("Firmware Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(firmware.isUpdating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startUpdate()
                    } label: {
                        if firmware.isUpdating {
                            ProgressView()
                        } else {
                            Text("Push")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canStart)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var bundledSection: some View {
        Section("Bundled firmware") {
            LabeledContent("Version", value: firmware.availableFirmwareVersion ?? "—")
            LabeledContent("Source",
                value: firmware.firmwarePath?.lastPathComponent ?? "Not available")
                .font(.callout.monospaced())
        }
    }

    private var boardsSection: some View {
        Section {
            if esp32Cameras.isEmpty {
                Text("No ESP32 boards configured")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    if selectedCameraIds.count == esp32Cameras.count {
                        selectedCameraIds.removeAll()
                    } else {
                        selectedCameraIds = Set(esp32Cameras.map { $0.id })
                    }
                } label: {
                    Label(
                        selectedCameraIds.count == esp32Cameras.count ? "Deselect all" : "Select all",
                        systemImage: selectedCameraIds.count == esp32Cameras.count
                            ? "checklist.unchecked" : "checklist.checked"
                    )
                }

                ForEach(esp32Cameras) { camera in
                    HStack {
                        Image(systemName: selectedCameraIds.contains(camera.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedCameraIds.contains(camera.id) ? Theme.accent : Theme.label3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(camera.name).font(.body.weight(.medium))
                            Text(camera.ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let connected = cameraManager.cameraStates[camera.id]?.isConnected,
                           connected {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Theme.green)
                                .font(.system(size: 8))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedCameraIds.contains(camera.id) {
                            selectedCameraIds.remove(camera.id)
                        } else {
                            selectedCameraIds.insert(camera.id)
                        }
                    }
                }
            }
        } header: {
            Text("Boards to flash")
        }
    }

    private var statusSection: some View {
        Section("Progress") {
            ForEach(esp32Cameras.filter { firmware.boardStatuses[$0.id] != nil }) { camera in
                if let status = firmware.boardStatuses[camera.id] {
                    HStack {
                        statusIcon(status)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(camera.name).font(.body.weight(.medium))
                            Text(status.displayText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if case .downloading(let pct) = status {
                            Text("\(pct)%")
                                .font(.body.monospaced())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: FirmwareUpdateManager.BoardStatus) -> some View {
        switch status {
        case .idle:
            Image(systemName: "circle").foregroundStyle(Theme.label3)
        case .starting, .downloading, .flashing, .rebooting:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.red)
        }
    }

    private func startUpdate() {
        let cams = esp32Cameras.filter { selectedCameraIds.contains($0.id) }
        Task {
            await firmware.startUpdate(cameras: cams)
        }
    }
}
