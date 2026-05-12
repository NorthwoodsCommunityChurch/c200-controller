import Foundation

/// Settings for a single camera within a preset
struct CameraSettings: Codable, Equatable {
    var aperture: String?
    var iso: String?
    var shutter: String?
    var ndFilter: String?
    var wbMode: String?
    var wbKelvin: String?
    var aeShift: String?

    var isEmpty: Bool {
        aperture == nil && iso == nil && shutter == nil &&
        ndFilter == nil && wbMode == nil && wbKelvin == nil && aeShift == nil
    }

    var includedSettings: [PresetSettingType] {
        var settings: [PresetSettingType] = []
        if aperture != nil { settings.append(.aperture) }
        if iso != nil { settings.append(.iso) }
        if shutter != nil { settings.append(.shutter) }
        if ndFilter != nil { settings.append(.ndFilter) }
        if wbMode != nil { settings.append(.wbMode) }
        if wbKelvin != nil { settings.append(.wbKelvin) }
        if aeShift != nil { settings.append(.aeShift) }
        return settings
    }
}

/// Settings for all cameras in a preset, keyed by camera ID
struct PresetSettings: Codable, Equatable {
    var cameraSettings: [String: CameraSettings] = [:]

    var isEmpty: Bool {
        cameraSettings.isEmpty || cameraSettings.values.allSatisfy { $0.isEmpty }
    }

    /// Get all unique setting types included across all cameras
    var allIncludedSettings: [PresetSettingType] {
        var settings = Set<PresetSettingType>()
        for camSettings in cameraSettings.values {
            for setting in camSettings.includedSettings {
                settings.insert(setting)
            }
        }
        return Array(settings).sorted { $0.rawValue < $1.rawValue }
    }

    /// Get camera count with settings
    var cameraCount: Int {
        cameraSettings.filter { !$0.value.isEmpty }.count
    }
}

/// Types of settings that can be included in a preset
enum PresetSettingType: String, CaseIterable {
    case aperture
    case iso
    case shutter
    case ndFilter
    case wbMode
    case wbKelvin
    case aeShift

    var displayName: String {
        switch self {
        case .aperture: return "Aperture"
        case .iso: return "ISO"
        case .shutter: return "Shutter"
        case .ndFilter: return "ND Filter"
        case .wbMode: return "WB Mode"
        case .wbKelvin: return "WB Kelvin"
        case .aeShift: return "AE Shift"
        }
    }
}

/// A saved camera preset
struct CameraPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var settings: PresetSettings
    var createdAt: Date

    init(id: UUID = UUID(), name: String, settings: PresetSettings = PresetSettings(), createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.settings = settings
        self.createdAt = createdAt
    }
}
