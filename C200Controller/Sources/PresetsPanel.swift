import SwiftUI

struct PresetsPanel: View {
    @EnvironmentObject var presetManager: PresetManager
    @EnvironmentObject var cameraManager: CameraManager
    @State private var newPresetName = ""
    @State private var showingAddPreset = false
    @State private var editingName: UUID?
    @State private var editedName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Presets")
                    .font(.headline)
                Spacer()
                Button(action: { showingAddPreset = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(presetManager.isEditingPreset)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Edit mode banner
            if presetManager.isEditingPreset {
                EditModeBanner()
            }

            // Presets list
            if presets.isEmpty && !showingAddPreset {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "slider.horizontal.3")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No presets yet")
                        .foregroundStyle(.secondary)
                    Text("Click + to create one")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Add preset field
                        if showingAddPreset {
                            AddPresetRow(
                                name: $newPresetName,
                                onSave: addPreset,
                                onCancel: { showingAddPreset = false; newPresetName = "" }
                            )
                        }

                        // Existing presets
                        ForEach(presets) { preset in
                            PresetRow(
                                preset: preset,
                                isEditing: editingName == preset.id,
                                editedName: $editedName,
                                onStartRename: {
                                    editingName = preset.id
                                    editedName = preset.name
                                },
                                onSaveRename: {
                                    presetManager.renamePreset(preset, to: editedName)
                                    editingName = nil
                                },
                                onCancelRename: { editingName = nil },
                                onEdit: { presetManager.startEditing(preset) },
                                onRecall: { recallPreset(preset) },
                                onDelete: { presetManager.deletePreset(preset) }
                            )
                            .disabled(presetManager.isEditingPreset && presetManager.editingPresetId != preset.id)
                        }
                    }
                    .padding()
                }
            }

            Spacer(minLength: 0)

            Divider()

            // Auto-reconnect toggle
            AutoReconnectToggle()
        }
        .frame(width: 250)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var presets: [CameraPreset] {
        presetManager.presets.sorted { $0.createdAt > $1.createdAt }
    }

    private func addPreset() {
        guard !newPresetName.isEmpty else { return }
        _ = presetManager.addPreset(name: newPresetName)
        newPresetName = ""
        showingAddPreset = false
    }

    private func recallPreset(_ preset: CameraPreset) {
        appLog("Recalling preset '\(preset.name)'")
        appLog("  Preset camera keys: \(Array(preset.settings.cameraSettings.keys))")
        appLog("  Connected cameras: \(cameraManager.cameraStates.filter { $0.value.isConnected }.map { "\($0.key) (\($0.value.camera.name))" })")

        for (cameraId, state) in cameraManager.cameraStates {
            if state.isConnected {
                if let camSettings = preset.settings.cameraSettings[cameraId] {
                    appLog("  ✅ Match! Applying to \(cameraId): iso=\(camSettings.iso ?? "nil")")
                    Task {
                        await state.applyPreset(camSettings)
                    }
                } else {
                    appLog("  ❌ No match for camera '\(cameraId)' — preset has keys: \(Array(preset.settings.cameraSettings.keys))")
                }
            }
        }
    }
}

struct EditModeBanner: View {
    @EnvironmentObject var presetManager: PresetManager

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                Text("Edit Mode")
                    .fontWeight(.medium)
            }

            Text("Click settings on camera tiles to include them in this preset")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Cancel") {
                    presetManager.cancelEditing()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    presetManager.saveEditing()
                }
                .buttonStyle(.borderedProminent)
                .disabled(presetManager.editingSettings.isEmpty)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1))
    }
}

struct AddPresetRow: View {
    @Binding var name: String
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack {
            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSave)

            Button(action: onSave) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .disabled(name.isEmpty)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct PresetRow: View {
    let preset: CameraPreset
    let isEditing: Bool
    @Binding var editedName: String
    var onStartRename: () -> Void
    var onSaveRename: () -> Void
    var onCancelRename: () -> Void
    var onEdit: () -> Void
    var onRecall: () -> Void
    var onDelete: () -> Void

    @EnvironmentObject var presetManager: PresetManager
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Name row
            HStack {
                if isEditing {
                    TextField("Name", text: $editedName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(onSaveRename)

                    Button(action: onSaveRename) {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.plain)

                    Button(action: onCancelRename) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(preset.name)
                        .fontWeight(.medium)
                        .onTapGesture(count: 2, perform: onStartRename)

                    Spacer()

                    if isCurrentlyEditing {
                        Text("Editing")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
            }

            // Settings summary
            if !preset.settings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(preset.settings.cameraCount) camera\(preset.settings.cameraCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        ForEach(preset.settings.allIncludedSettings, id: \.self) { setting in
                            Text(settingAbbreviation(setting))
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(3)
                        }
                    }
                }
            }

            // Action buttons
            if !presetManager.isEditingPreset {
                HStack(spacing: 8) {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: onRecall) {
                        Label("Recall", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(preset.settings.isEmpty)

                    Spacer()

                    if isHovering {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(isCurrentlyEditing ? Color.orange.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrentlyEditing ? Color.orange : Color.clear, lineWidth: 2)
        )
        .onHover { isHovering = $0 }
    }

    private var isCurrentlyEditing: Bool {
        presetManager.isEditingPreset && presetManager.editingPresetId == preset.id
    }

    private func settingAbbreviation(_ type: PresetSettingType) -> String {
        switch type {
        case .aperture: return "Av"
        case .iso: return "ISO"
        case .shutter: return "Tv"
        case .ndFilter: return "ND"
        case .wbMode: return "WB"
        case .wbKelvin: return "K"
        case .aeShift: return "AE"
        }
    }
}

struct AutoReconnectToggle: View {
    @EnvironmentObject var cameraManager: CameraManager

    var body: some View {
        Toggle(isOn: $cameraManager.autoReconnect) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Auto-reconnect")
            }
        }
        .toggleStyle(.switch)
        .padding()
    }
}

#Preview {
    PresetsPanel()
        .environmentObject(PresetManager())
        .environmentObject(CameraManager())
}
