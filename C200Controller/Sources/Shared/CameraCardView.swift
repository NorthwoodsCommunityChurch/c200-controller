import SwiftUI

struct CameraCardView: View {
    let camera: Camera
    @ObservedObject var state: CameraState
    /// When tapped (anywhere outside an interactive subview), the host can
    /// open a detail/inspector sheet. Phase 2 wires this to camera settings.
    var onOpenDetail: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 12)

            if state.isConnected {
                metricsGrid
                    .padding(.bottom, 10)
                tallyStrip
                    .padding(.bottom, 10)
                recordButton
            } else {
                offlineBlock
            }
        }
        .padding(14)
        .frame(minHeight: 230)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .shadow(color: glowColor, radius: glowRadius)
        .opacity(state.isConnected ? 1.0 : 0.55)
        .animation(.easeInOut(duration: 0.15), value: state.tallyProgram)
        .animation(.easeInOut(duration: 0.15), value: state.tallyPreview)
        .animation(.easeInOut(duration: 0.2), value: state.isRecording)
        .animation(.easeInOut(duration: 0.2), value: state.isConnected)
    }

    // MARK: - Header
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            // Tappable name area → open camera detail sheet
            Button {
                onOpenDetail?()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(camera.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    Text(subline)
                        .font(.techMono(10, weight: .regular))
                        .foregroundStyle(Theme.label2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if state.isRecording {
                recBadge
            }

            // Settings/detail button on the right
            Button {
                onOpenDetail?()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.label2)
            }
            .buttonStyle(.plain)
        }
    }

    private var subline: String {
        var parts = [camera.ip]
        if camera.tslIndex > 0 { parts.append("TSL \(camera.tslIndex)") }
        return parts.joined(separator: " · ")
    }

    private var recBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.red)
                .frame(width: 6, height: 6)
            Text("REC")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(Theme.red)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.redTint, in: Capsule())
    }

    // MARK: - Metrics
    private var metricsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                  spacing: 6) {
            ForEach(MetricControl.allCases) { control in
                MetricTile(control: control, state: state)
            }
        }
    }

    // MARK: - Tally
    private var tallyStrip: some View {
        HStack(spacing: 6) {
            TallyChip(label: "PGM", isOn: state.tallyProgram, color: Theme.red)
            TallyChip(label: "PVW", isOn: state.tallyPreview, color: Theme.green)
        }
    }

    // MARK: - Record button — wired to state.toggleRecord()
    private var recordButton: some View {
        Button {
            state.toggleRecord()
        } label: {
            HStack(spacing: 7) {
                if state.isRecording {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white)
                        .frame(width: 11, height: 11)
                    Text("STOP")
                } else {
                    Circle()
                        .fill(Theme.red)
                        .frame(width: 12, height: 12)
                    Text("REC")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .foregroundStyle(state.isRecording ? .white : Theme.label)
            .background(state.isRecording ? Theme.red : Theme.bgCardElevated,
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(state.isRecording ? Theme.red : Theme.label4, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Offline
    private var offlineBlock: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text("Offline")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.label2)
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.label2)
                Text("Reconnecting…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.label3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Border / glow based on tally
    private var borderColor: Color {
        if state.tallyProgram { return Theme.red }
        if state.tallyPreview { return Theme.green }
        return Theme.label4
    }
    private var borderWidth: CGFloat {
        (state.tallyProgram || state.tallyPreview) ? 2 : 1
    }
    private var glowColor: Color {
        if state.tallyProgram { return Theme.red.opacity(0.55) }
        if state.tallyPreview { return Theme.green.opacity(0.45) }
        return .clear
    }
    private var glowRadius: CGFloat {
        (state.tallyProgram || state.tallyPreview) ? 16 : 0
    }
}

// MARK: - Metric Tile (tappable → opens MetricControlPopover)

struct MetricTile: View {
    let control: MetricControl
    @ObservedObject var state: CameraState
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            VStack(spacing: 2) {
                Image(systemName: control.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(control.tint)
                    .frame(height: 13)
                Text(control.label.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.label2)
                Text(displayValue)
                    .font(.techMono(13))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.label4, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            #if os(iOS)
            MetricControlPopover(control: control, state: state)
                .presentationCompactAdaptation(.popover)
            #else
            MetricControlPopover(control: control, state: state)
            #endif
        }
    }

    private var displayValue: String {
        let raw = control.value(from: state)
        return raw.isEmpty ? "—" : raw
    }
}

// MARK: - Tally Chip

struct TallyChip: View {
    let label: String
    let isOn: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOn ? color : Theme.label3)
                .frame(width: 10, height: 10)
                .shadow(color: isOn ? color : .clear, radius: 5)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(isOn ? color : Theme.label3)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(isOn ? color.opacity(0.18) : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 9))
    }
}
