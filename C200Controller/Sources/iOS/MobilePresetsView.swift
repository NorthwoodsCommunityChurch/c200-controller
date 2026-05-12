import SwiftUI

/// Phase 3 — iPad presets list. Tap to recall. Swipe to delete.
/// "Save current as preset" captures the live state of every connected
/// camera. Per-setting edit is deferred — operators usually recall full
/// snapshots in production.
struct MobilePresetsView: View {
    @EnvironmentObject var presetManager: PresetManager
    @EnvironmentObject var cameraManager: CameraManager
    @State private var showingAddPreset = false
    @State private var newPresetName = ""
    @State private var renamingPreset: CameraPreset?
    @State private var renameDraft = ""
    @State private var recallingId: UUID?

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            if presetManager.presets.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(presetManager.presets) { preset in
                            presetRow(preset)
                        }
                        .onDelete { indexSet in
                            for idx in indexSet {
                                presetManager.deletePreset(presetManager.presets[idx])
                            }
                        }
                    } header: {
                        Text("\(presetManager.presets.count) preset\(presetManager.presets.count == 1 ? "" : "s")")
                    } footer: {
                        Text("Tap a preset to recall its saved settings on every camera it covers. Swipe a row to delete.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Presets")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newPresetName = ""
                    showingAddPreset = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New preset", isPresented: $showingAddPreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Cancel", role: .cancel) { }
            Button("Save") { addPreset() }
        } message: {
            Text("Captures the current state of every connected camera.")
        }
        .alert("Rename preset", isPresented: Binding(
            get: { renamingPreset != nil },
            set: { if !$0 { renamingPreset = nil } }
        )) {
            TextField("Preset name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingPreset = nil }
            Button("Save") {
                if let p = renamingPreset {
                    presetManager.renamePreset(p, to: renameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                renamingPreset = nil
            }
        }
    }

    // MARK: - Rows

    private func presetRow(_ preset: CameraPreset) -> some View {
        Button {
            recall(preset)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.accentTint)
                        .frame(width: 36, height: 36)
                    if recallingId == preset.id {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Image(systemName: "slider.horizontal.below.rectangle")
                            .foregroundStyle(Theme.accent)
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.label)
                    Text(subtitle(for: preset))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.label3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameDraft = preset.name
                renamingPreset = preset
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                presetManager.deletePreset(preset)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func subtitle(for preset: CameraPreset) -> String {
        let cams = preset.settings.cameraCount
        let types = preset.settings.allIncludedSettings.count
        let camsText = "\(cams) camera\(cams == 1 ? "" : "s")"
        let typesText = "\(types) setting\(types == 1 ? "" : "s")"
        return "\(camsText) · \(typesText)"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No presets yet", systemImage: "slider.horizontal.3")
        } description: {
            Text("Capture the current camera state as a recall-able preset.")
        } actions: {
            Button {
                newPresetName = ""
                showingAddPreset = true
            } label: {
                Label("Create preset", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func addPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = presetManager.addPreset(name: name)
        // Capture the current state of every connected camera into this preset.
        var settings = PresetSettings()
        for camera in cameraManager.cameras {
            guard let cs = cameraManager.cameraStates[camera.id], cs.isConnected else { continue }
            var cam = CameraSettings()
            cam.aperture = cs.aperture.nonEmpty
            cam.iso = cs.iso.nonEmpty
            cam.shutter = cs.shutter.nonEmpty
            cam.ndFilter = cs.ndFilter.nonEmpty
            cam.wbMode = cs.wbMode.nonEmpty
            cam.wbKelvin = cs.wbKelvin.nonEmpty
            cam.aeShift = cs.aeShift.nonEmpty
            if !cam.isEmpty {
                settings.cameraSettings[camera.id] = cam
            }
        }
        presetManager.updatePresetSettings(preset, settings: settings)
    }

    private func recall(_ preset: CameraPreset) {
        recallingId = preset.id
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for (cameraId, settings) in preset.settings.cameraSettings {
                    guard let state = cameraManager.cameraStates[cameraId],
                          state.isConnected else { continue }
                    group.addTask { @MainActor in
                        await state.applyPreset(settings)
                    }
                }
            }
            recallingId = nil
        }
    }
}

private extension String {
    /// Returns nil when the string is empty, otherwise self. Used to convert
    /// "" → nil for optional fields in CameraSettings.
    var nonEmpty: String? { isEmpty ? nil : self }
}
