import SwiftUI

enum AddCameraMode: String, CaseIterable, Identifiable {
    case esp32 = "ESP32 Bridge"
    case direct = "Direct Camera"
    var id: String { rawValue }
}

struct AddCameraSheet: View {
    @EnvironmentObject var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    @State private var mode: AddCameraMode = .esp32
    @State private var manualESP32IP = ""
    @State private var manualCameraIP = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Connection", selection: $mode) {
                        ForEach(AddCameraMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)

                if mode == .esp32 {
                    esp32Sections
                } else {
                    directCameraSection
                }
            }
            .navigationTitle("Add Camera")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #endif
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
    }

    // MARK: - ESP32 mode

    @ViewBuilder
    private var esp32Sections: some View {
        Section {
            if cameraManager.discoveredESP32s.isEmpty {
                HStack {
                    if cameraManager.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Text(cameraManager.isScanning ? "Searching…" : "No ESP32s found")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        cameraManager.refreshDiscovery()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            } else {
                ForEach(cameraManager.discoveredESP32s) { esp in
                    let alreadyAdded = cameraManager.cameras.contains { $0.id == esp.id }
                    HStack(spacing: 10) {
                        Image(systemName: "wifi")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(esp.name).font(.body.weight(.medium))
                            Text(esp.ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if alreadyAdded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.green)
                        } else {
                            Button("Add") {
                                cameraManager.addESP32Manually(ip: esp.ip)
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Discovered on this network")
                Spacer()
                Button {
                    cameraManager.refreshDiscovery()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.bold())
                }
            }
        }

        Section("Add by IP") {
            HStack {
                TextField("ESP32 IP address", text: $manualESP32IP)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Add") {
                    let ip = manualESP32IP.trimmingCharacters(in: .whitespaces)
                    guard !ip.isEmpty else { return }
                    cameraManager.addESP32Manually(ip: ip)
                    manualESP32IP = ""
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualESP32IP.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Direct mode

    @ViewBuilder
    private var directCameraSection: some View {
        Section {
            HStack {
                TextField("Camera IP address", text: $manualCameraIP)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Add") {
                    let ip = manualCameraIP.trimmingCharacters(in: .whitespaces)
                    guard !ip.isEmpty else { return }
                    cameraManager.addDirectCamera(ip: ip)
                    manualCameraIP = ""
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualCameraIP.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Connect directly to Canon C200 Browser Remote")
        } footer: {
            Text("Default credentials: admin / admin (configured in the Canon menu).")
        }
    }
}
