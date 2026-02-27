import SwiftUI

struct CameraPositionsSettingsView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @Environment(\.dismiss) var dismiss

    @State private var hostText = ""
    @State private var portText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Camera Positions")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // Enable toggle + status
                HStack {
                    Circle()
                        .fill(cameraManager.positionsEnabled ? Color.success : Color(white: 0.35))
                        .frame(width: 8, height: 8)
                    Text("Camera Positions App")
                        .font(.caption)
                    Text(cameraManager.positionsEnabled ? "Polling" : "Off")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Toggle("Enable", isOn: Binding(
                        get: { cameraManager.positionsEnabled },
                        set: { enabled in
                            if enabled {
                                cameraManager.positionsHost = hostText
                                cameraManager.positionsPort = Int(portText) ?? 8765
                                cameraManager.startPositions()
                            } else {
                                cameraManager.stopPositions()
                            }
                        }
                    ))
                }

                // Host + Port fields
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("Host:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("IP or hostname", text: $hostText)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }

                    HStack(spacing: 6) {
                        Text("Port:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("8765", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(width: 60)
                    }

                    Button("Apply") {
                        cameraManager.stopPositions()
                        cameraManager.positionsHost = hostText
                        cameraManager.positionsPort = Int(portText) ?? 8765
                        if cameraManager.positionsEnabled {
                            cameraManager.startPositions()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider()

                Text("Assign camera position numbers using the gear icon (⚙) on each camera tile.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Spacer()
        }
        .frame(width: 440, height: 230)
        .onAppear {
            hostText = cameraManager.positionsHost
            portText = cameraManager.positionsPort > 0 ? "\(cameraManager.positionsPort)" : "8765"
        }
    }
}
