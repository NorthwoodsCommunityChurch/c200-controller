import SwiftUI

/// iPhone full-screen camera control. Big touch targets, scrollable.
/// Replaces the iPad-style metric popover (which feels cramped at compact width).
struct iPhoneCameraDetailView: View {
    let cameraId: String
    @EnvironmentObject var cameraManager: CameraManager
    @State private var showingMoreSheet = false

    private var camera: Camera? {
        cameraManager.cameras.first { $0.id == cameraId }
    }
    private var state: CameraState? {
        cameraManager.cameraStates[cameraId]
    }

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            if let camera, let state {
                ScrollView {
                    VStack(spacing: 14) {
                        statusCard(camera: camera, state: state)
                        tallyCard(state: state)
                        recordCard(state: state)
                        controlsGrid(state: state)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("Camera removed", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(camera?.name ?? "Camera")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingMoreSheet = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingMoreSheet) {
            CameraDetailSheet(cameraId: cameraId)
                .environmentObject(cameraManager)
        }
    }

    // MARK: - Cards

    private func statusCard(camera: Camera, state: CameraState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(state.isConnected ? Theme.green : Theme.red)
                    .frame(width: 10, height: 10)
                Text(state.isConnected ? "Connected" : (state.isConnecting ? "Connecting…" : "Offline"))
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Text(camera.ip)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 16))
    }

    private func tallyCard(state: CameraState) -> some View {
        HStack(spacing: 10) {
            TallyChip(label: "PGM", isOn: state.tallyProgram, color: Theme.red)
            TallyChip(label: "PVW", isOn: state.tallyPreview, color: Theme.green)
        }
        .frame(height: 56)
    }

    private func recordCard(state: CameraState) -> some View {
        Button {
            state.toggleRecord()
        } label: {
            HStack(spacing: 10) {
                if state.isRecording {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white)
                        .frame(width: 16, height: 16)
                    Text("STOP RECORDING")
                } else {
                    Circle()
                        .fill(Theme.red)
                        .frame(width: 18, height: 18)
                    Text("START RECORDING")
                }
            }
            .font(.system(size: 15, weight: .bold))
            .tracking(0.5)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(state.isRecording ? .white : Theme.label)
            .background(state.isRecording ? Theme.red : Theme.bgCardElevated,
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(state.isRecording ? Theme.red : Theme.label4, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!state.isConnected)
        .opacity(state.isConnected ? 1.0 : 0.5)
    }

    private func controlsGrid(state: CameraState) -> some View {
        VStack(spacing: 10) {
            ForEach(MetricControl.allCases) { control in
                bigControlRow(control: control, state: state)
            }
        }
    }

    private func bigControlRow(control: MetricControl, state: CameraState) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: control.icon)
                    .foregroundStyle(control.tint)
                    .font(.system(size: 16))
                Text(control.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Spacer()
                Text(control.value(from: state).isEmpty ? "—" : control.value(from: state))
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                bigCircleButton(systemName: "minus") {
                    control.minus(on: state)
                }
                if state.isCommandPending {
                    ProgressView().tint(Theme.label2).frame(width: 24)
                } else {
                    Spacer().frame(width: 24)
                }
                bigCircleButton(systemName: "plus") {
                    control.plus(on: state)
                }
                if control == .whiteBalance {
                    // Quick AWB toggle inline for white balance
                    Button {
                        state.setWhiteBalance("awb")
                    } label: {
                        Text("AWB")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(state.wbMode == "awb" ? Theme.accent : Theme.bgCardElevated,
                                        in: Capsule())
                            .foregroundStyle(state.wbMode == "awb" ? .white : Theme.label)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 16))
    }

    private func bigCircleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "\(systemName).circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(state?.isCommandPending == true ? Theme.label3 : Theme.accent)
        }
        .buttonStyle(.plain)
        .disabled(state?.isCommandPending ?? false)
        .frame(maxWidth: .infinity)
    }
}
