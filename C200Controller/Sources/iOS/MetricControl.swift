import SwiftUI

/// One of the six adjustable camera metrics. Knows how to display itself and
/// how to apply +/- adjustments against a `CameraState`.
///
/// Note on aperture: the camera's `iris/plus` command stops the lens DOWN
/// (smaller aperture, higher f-number). The UI presents "+" as the user-visible
/// "open up" direction, so we invert just for aperture. Other metrics map 1:1.
enum MetricControl: String, CaseIterable, Identifiable {
    case aperture, iso, shutter, aeShift, whiteBalance, nd
    var id: String { rawValue }

    var label: String {
        switch self {
        case .aperture: return "Av"
        case .iso: return "ISO"
        case .shutter: return "Tv"
        case .aeShift: return "AE"
        case .whiteBalance: return "WB"
        case .nd: return "ND"
        }
    }

    var title: String {
        switch self {
        case .aperture: return "Aperture"
        case .iso: return "ISO"
        case .shutter: return "Shutter"
        case .aeShift: return "AE Shift"
        case .whiteBalance: return "White Balance"
        case .nd: return "ND Filter"
        }
    }

    var icon: String {
        switch self {
        case .aperture: return "camera.aperture"
        case .iso: return "sun.max.fill"
        case .shutter: return "timer"
        case .aeShift: return "plusminus"
        case .whiteBalance: return "thermometer.sun"
        case .nd: return "circle.lefthalf.filled"
        }
    }

    var tint: Color {
        switch self {
        case .aperture: return Theme.indigo
        case .iso: return Theme.orange
        case .shutter: return Theme.purple
        case .aeShift: return Theme.yellow
        case .whiteBalance: return Theme.teal
        case .nd: return Theme.label2
        }
    }

    @MainActor
    func value(from state: CameraState) -> String {
        switch self {
        case .aperture: return state.aperture
        case .iso: return state.iso
        case .shutter: return state.shutter
        case .aeShift: return state.aeShift
        case .whiteBalance: return state.wbKelvin
        case .nd: return state.ndFilter
        }
    }

    /// User-visible "+" — opens the lens / brightens.
    @MainActor
    func plus(on state: CameraState) {
        switch self {
        case .aperture:    state.sendCommand("iris", "minus")  // inverted
        case .iso:         state.sendCommand("iso", "plus")
        case .shutter:     state.sendCommand("shutter", "plus")
        case .aeShift:     state.sendCommand("aes", "plus")
        case .whiteBalance: state.sendCommand("wbk", "plus")
        case .nd:          state.sendCommand("nd", "plus")
        }
    }

    /// User-visible "−" — stops down / darkens.
    @MainActor
    func minus(on state: CameraState) {
        switch self {
        case .aperture:    state.sendCommand("iris", "plus")   // inverted
        case .iso:         state.sendCommand("iso", "minus")
        case .shutter:     state.sendCommand("shutter", "minus")
        case .aeShift:     state.sendCommand("aes", "minus")
        case .whiteBalance: state.sendCommand("wbk", "minus")
        case .nd:          state.sendCommand("nd", "minus")
        }
    }
}
