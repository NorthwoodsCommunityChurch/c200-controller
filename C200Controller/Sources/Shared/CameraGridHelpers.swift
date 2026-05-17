import SwiftUI

/// Add-camera grid tile shown at the end of the camera list on both iPad and
/// macOS. Tapping invokes `action`, which the host wires up to present
/// `AddCameraSheet`.
struct AddCameraCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.bgCard)
                        .frame(width: 44, height: 44)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.label)
                }
                Text("Add camera")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.label2)
                Text("Discover or enter IP")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.label3)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Theme.label4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Identifiable wrapper so `.sheet(item:)` can drive presentation from a
/// `String` camera id. Used by both the iPad grid and the new macOS dashboard.
struct CameraIDBox: Identifiable {
    let id: String
}
