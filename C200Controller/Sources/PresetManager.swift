import Foundation
import Combine


/// Manages camera presets with persistence
@MainActor
class PresetManager: ObservableObject {
    @Published var presets: [CameraPreset] = []

    // Edit mode state
    @Published var isEditingPreset = false
    @Published var editingPresetId: UUID?
    @Published var editingSettings = PresetSettings()  // Per-camera settings

    private let persistenceKey = "camera_presets_v1"

    init() {
        loadPresets()
    }

    // MARK: - Persistence

    private func loadPresets() {
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode([CameraPreset].self, from: data) {
            presets = decoded
            print("Loaded \(presets.count) presets from storage")
        }
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
            print("Saved \(presets.count) presets to storage")
        }
    }

    // MARK: - CRUD

    func addPreset(name: String) -> CameraPreset {
        let preset = CameraPreset(name: name)
        presets.append(preset)
        savePresets()
        return preset
    }

    func deletePreset(_ preset: CameraPreset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    func renamePreset(_ preset: CameraPreset, to newName: String) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index].name = newName
            savePresets()
        }
    }

    func updatePresetSettings(_ preset: CameraPreset, settings: PresetSettings) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index].settings = settings
            savePresets()
        }
    }

    // MARK: - Edit Mode

    func startEditing(_ preset: CameraPreset) {
        editingPresetId = preset.id
        editingSettings = preset.settings
        isEditingPreset = true
    }

    func cancelEditing() {
        isEditingPreset = false
        editingPresetId = nil
        editingSettings = PresetSettings()
    }

    // Toggle a setting for a specific camera in the current edit
    func toggleSetting(_ type: PresetSettingType, cameraId: String, currentValue: String) {
        // Get or create camera settings
        var camSettings = editingSettings.cameraSettings[cameraId] ?? CameraSettings()

        let wasIncluded: Bool
        switch type {
        case .aperture:
            wasIncluded = camSettings.aperture != nil
            camSettings.aperture = wasIncluded ? nil : currentValue
        case .iso:
            wasIncluded = camSettings.iso != nil
            camSettings.iso = wasIncluded ? nil : currentValue
        case .shutter:
            wasIncluded = camSettings.shutter != nil
            camSettings.shutter = wasIncluded ? nil : currentValue
        case .ndFilter:
            wasIncluded = camSettings.ndFilter != nil
            camSettings.ndFilter = wasIncluded ? nil : currentValue
        case .wbMode:
            wasIncluded = camSettings.wbMode != nil
            camSettings.wbMode = wasIncluded ? nil : currentValue
        case .wbKelvin:
            wasIncluded = camSettings.wbKelvin != nil
            camSettings.wbKelvin = wasIncluded ? nil : currentValue
        case .aeShift:
            wasIncluded = camSettings.aeShift != nil
            camSettings.aeShift = wasIncluded ? nil : currentValue
        }

        print("🔄 Toggle \(type.rawValue) for camera \(cameraId): \(wasIncluded ? "removed" : "added='\(currentValue)'")")

        // Update or remove camera settings
        if camSettings.isEmpty {
            editingSettings.cameraSettings.removeValue(forKey: cameraId)
        } else {
            editingSettings.cameraSettings[cameraId] = camSettings
        }
    }

    func savedValue(_ type: PresetSettingType, cameraId: String) -> String? {
        guard let camSettings = editingSettings.cameraSettings[cameraId] else { return nil }
        switch type {
        case .aperture: return camSettings.aperture
        case .iso: return camSettings.iso
        case .shutter: return camSettings.shutter
        case .ndFilter: return camSettings.ndFilter
        case .wbMode: return camSettings.wbMode
        case .wbKelvin: return camSettings.wbKelvin
        case .aeShift: return camSettings.aeShift
        }
    }

    func isSettingIncluded(_ type: PresetSettingType, cameraId: String) -> Bool {
        guard let camSettings = editingSettings.cameraSettings[cameraId] else { return false }
        switch type {
        case .aperture: return camSettings.aperture != nil
        case .iso: return camSettings.iso != nil
        case .shutter: return camSettings.shutter != nil
        case .ndFilter: return camSettings.ndFilter != nil
        case .wbMode: return camSettings.wbMode != nil
        case .wbKelvin: return camSettings.wbKelvin != nil
        case .aeShift: return camSettings.aeShift != nil
        }
    }

    // Update/capture current value for a setting (long press)
    func captureSettingValue(_ type: PresetSettingType, cameraId: String, currentValue: String) {
        appLog("💾 Capture \(type.rawValue) = '\(currentValue)' for camera \(cameraId)")
        var camSettings = editingSettings.cameraSettings[cameraId] ?? CameraSettings()
        switch type {
        case .aperture: camSettings.aperture = currentValue
        case .iso: camSettings.iso = currentValue
        case .shutter: camSettings.shutter = currentValue
        case .ndFilter: camSettings.ndFilter = currentValue
        case .wbMode: camSettings.wbMode = currentValue
        case .wbKelvin: camSettings.wbKelvin = currentValue
        case .aeShift: camSettings.aeShift = currentValue
        }
        editingSettings.cameraSettings[cameraId] = camSettings
        appLog("   All camera settings: \(camSettings)")
    }

    func saveEditing() {
        guard let presetId = editingPresetId,
              let index = presets.firstIndex(where: { $0.id == presetId }) else {
            cancelEditing()
            return
        }

        // Log what we're saving
        for (camId, camSettings) in editingSettings.cameraSettings {
            appLog("💾 Saving preset for camera \(camId): iso=\(camSettings.iso ?? "nil"), aperture=\(camSettings.aperture ?? "nil"), shutter=\(camSettings.shutter ?? "nil")")
        }

        presets[index].settings = editingSettings
        savePresets()

        isEditingPreset = false
        editingPresetId = nil
        editingSettings = PresetSettings()
    }
}
