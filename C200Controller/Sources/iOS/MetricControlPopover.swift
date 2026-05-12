import SwiftUI

/// Popover content shown when a metric tile is tapped. Renders the current
/// value large, provides +/- adjustment buttons, and for WB also shows mode
/// pickers.
struct MetricControlPopover: View {
    let control: MetricControl
    @ObservedObject var state: CameraState

    var body: some View {
        VStack(spacing: 18) {
            // Title
            HStack(spacing: 8) {
                Image(systemName: control.icon)
                    .foregroundStyle(control.tint)
                Text(control.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.label)
            }

            // Current value, large
            Text(control.value(from: state).isEmpty ? "—" : control.value(from: state))
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.label)
                .padding(.horizontal, 8)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            // +/- buttons (and WB mode, for white balance)
            if control == .whiteBalance {
                wbModePicker
                Divider().overlay(Theme.label4)
            }

            adjustButtons
        }
        .padding(24)
        .frame(minWidth: 280)
        .background(Theme.bgTertiary)
        .preferredColorScheme(.dark)
    }

    private var adjustButtons: some View {
        HStack(spacing: 28) {
            adjustButton(systemName: "minus.circle.fill") {
                control.minus(on: state)
            }
            if state.isCommandPending {
                ProgressView()
                    .tint(Theme.label2)
                    .frame(width: 24, height: 24)
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
            adjustButton(systemName: "plus.circle.fill") {
                control.plus(on: state)
            }
        }
    }

    private func adjustButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 52))
                .foregroundStyle(state.isCommandPending ? Theme.label3 : Theme.accent)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state.isCommandPending)
    }

    // MARK: - White Balance mode picker

    private var wbModePicker: some View {
        VStack(spacing: 10) {
            Text("Mode")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.label2)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                wbButton("AWB", mode: "awb")
                wbButton("☀︎", mode: "daylight")
                wbButton("💡", mode: "tungsten")
            }
            HStack(spacing: 8) {
                wbButton("User 1", mode: "user1")
                wbButton("Set A", mode: "seta")
                wbButton("Set B", mode: "setb")
            }
            HStack(spacing: 6) {
                Text("Mode:")
                    .font(.caption2)
                    .foregroundStyle(Theme.label2)
                Text(state.wbMode)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.label)
            }
            .padding(.top, 2)
        }
    }

    private func wbButton(_ label: String, mode: String) -> some View {
        let isActive = state.wbMode == mode
        return Button {
            state.setWhiteBalance(mode)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: 56)
                .background(isActive ? Theme.accent : Theme.bgCard,
                            in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(isActive ? Color.white : Theme.label)
        }
        .buttonStyle(.plain)
    }
}
