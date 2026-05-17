import SwiftUI

/// Tally Sources panel — the production answer to "what UMD ID is each camera
/// supposed to filter for". Lives inside the new macOS dashboard.
///
/// Data flow it surfaces:
///   Carbonite → TSL (TCP :5201) → dashboard's TSLClient
///   dashboard renders every discovered UMD ID with its switcher-provided name
///   operator assigns each discovered ID to a camera
///   dashboard pushes `tsl_config` over WebSocket to that camera's ESP32 box
///   box stores the index in NVS, filters the TSL stream for that ID, lights LED
///
/// The dashboard is NOT in the tally hot path. This view only configures the
/// filter on each box.
struct TallySourcesView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @Binding var showingTSLDiagnostics: Bool
    @Binding var showingTallySettings: Bool
    @State private var lastPushAt: Date?

    private var sortedSources: [TSLDiscoveredID] {
        // Stable ordering by UMD ID ascending so the list doesn't shuffle as
        // PGM/PVW state flicks between sources. The live state is shown in
        // the State column — order shouldn't depend on it.
        cameraManager.discoveredTSLIDs.values.sorted { $0.umdID < $1.umdID }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bgPrimary.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sourcesSection
                        assignmentsSection
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            // Belt-and-suspenders: every time the operator opens this view, force
            // every connected box to re-receive its tsl_config so dashboard intent
            // and box NVS are guaranteed to agree.
            pushNow()
        }
    }

    private func pushNow() {
        cameraManager.pushTslConfigToAll()
        lastPushAt = Date()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tally Sources")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.label)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.label2)
            }
            Spacer()
            tslPill
            Button {
                pushNow()
            } label: {
                Label("Push to boxes", systemImage: "arrow.up.to.line")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .help("Re-send the current UMD assignment to every connected ESP32 box now.")
            Button {
                showingTSLDiagnostics = true
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            Button {
                showingTallySettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.label4).frame(height: 0.5)
        }
    }

    private var headerSubtitle: String {
        let pushNote: String
        if let last = lastPushAt {
            let elapsed = Int(Date().timeIntervalSince(last))
            pushNote = elapsed < 2 ? "  ·  Pushed to boxes just now" : "  ·  Pushed to boxes \(elapsed)s ago"
        } else {
            pushNote = ""
        }
        if !cameraManager.tslEnabled {
            return "TSL listener is off. Turn it on in Tally Settings.\(pushNote)"
        }
        if !cameraManager.tslListening {
            return "Listener failed to bind to TCP :\(cameraManager.tslPort)\(pushNote)"
        }
        if !cameraManager.tslClientConnected {
            return "Listening on TCP :\(cameraManager.tslPort) — no switcher connected yet\(pushNote)"
        }
        let n = cameraManager.discoveredTSLIDs.count
        return "Switcher is sending \(n) UMD ID\(n == 1 ? "" : "s"). Assign each to a camera below.\(pushNote)"
    }

    private var tslPill: some View {
        let connected = cameraManager.tslClientConnected
        let listening = cameraManager.tslListening
        let color: Color = connected ? Theme.green : (listening ? Theme.yellow : Theme.label3)
        let label = connected ? "TSL · Live" : (listening ? "TSL · Listening" : "TSL · Off")
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(color.opacity(0.18), in: Capsule())
    }

    // MARK: - Discovered sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Discovered sources", systemImage: "antenna.radiowaves.left.and.right")
            sourcesTable
        }
    }

    @ViewBuilder
    private var sourcesTable: some View {
        if sortedSources.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                tableHeader
                Divider().overlay(Theme.label4)
                ForEach(Array(sortedSources.enumerated()), id: \.element.id) { idx, source in
                    SourceRow(source: source)
                        .background(idx.isMultiple(of: 2) ? Color.white.opacity(0.02) : Color.clear)
                    Divider().overlay(Theme.label4)
                }
            }
            .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.label4, lineWidth: 0.5)
            )
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            columnHeader("Source", width: nil)
            columnHeader("UMD ID", width: 80)
            columnHeader("State", width: 90)
            columnHeader("Packets", width: 80)
            columnHeader("Assigned camera", width: 220)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func columnHeader(_ title: String, width: CGFloat?) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.label2)
            .frame(width: width, alignment: width == nil ? .leading : .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 28))
                .foregroundStyle(Theme.label3)
            Text(emptyStateTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.label2)
            Text(emptyStateSubtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.label3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Theme.label4)
        )
    }

    private var emptyStateTitle: String {
        if !cameraManager.tslEnabled { return "TSL listener is off" }
        if !cameraManager.tslClientConnected { return "Waiting for switcher" }
        return "No UMD IDs received yet"
    }
    private var emptyStateSubtitle: String {
        if !cameraManager.tslEnabled {
            return "Open Tally Settings (⌘⇧T) and toggle TSL on."
        }
        if !cameraManager.tslClientConnected {
            return "Listening on TCP :\(cameraManager.tslPort). Configure your switcher to send TSL 3.1 or 5.0 to this Mac's IP."
        }
        return "Switcher is connected but hasn't sent any UMD data."
    }

    // MARK: - Camera assignments side

    private var assignmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Camera filters", systemImage: "video.fill")
            if cameraManager.cameras.isEmpty {
                Text("No cameras added yet — use Cameras → Add Camera.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.label2)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(cameraManager.cameras.enumerated()), id: \.element.id) { idx, camera in
                        CameraAssignmentRow(camera: camera)
                            .background(idx.isMultiple(of: 2) ? Color.white.opacity(0.02) : Color.clear)
                        if idx < cameraManager.cameras.count - 1 {
                            Divider().overlay(Theme.label4)
                        }
                    }
                }
                .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.label4, lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(Theme.label2)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.label2)
        }
        .padding(.bottom, 2)
    }
}

// MARK: - Source row (one discovered UMD ID)

private struct SourceRow: View {
    let source: TSLDiscoveredID
    @EnvironmentObject var cameraManager: CameraManager

    private var assignedCamera: Camera? {
        cameraManager.cameras.first(where: { $0.tslIndex == source.umdID })
    }

    private var stateColor: Color {
        if source.isProgram { return Theme.red }
        if source.isPreview { return Theme.green }
        return Theme.label3
    }
    private var stateLabel: String {
        if source.isProgram { return "PGM" }
        if source.isPreview { return "PVW" }
        return "—"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Source name (flexible)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName.isEmpty ? "Unnamed source" : source.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text(relativeLastSeen)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.label3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // UMD ID
            Text("\(source.umdID)")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.label)
                .frame(width: 80, alignment: .leading)

            // State pill
            HStack(spacing: 5) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: stateColor.opacity(0.6),
                            radius: (source.isProgram || source.isPreview) ? 4 : 0)
                Text(stateLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(stateColor)
            }
            .frame(width: 90, alignment: .leading)

            // Packet count
            Text("\(source.packetCount)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.label2)
                .frame(width: 80, alignment: .leading)

            // Camera assignment menu
            cameraAssignmentMenu
                .frame(width: 220, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var relativeLastSeen: String {
        let elapsed = Date().timeIntervalSince(source.lastSeen)
        if elapsed < 2 { return "just now" }
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        return "older"
    }

    @ViewBuilder
    private var cameraAssignmentMenu: some View {
        Menu {
            Button {
                if let cam = assignedCamera {
                    cameraManager.setTslIndex(for: cam.id, index: 0)
                }
            } label: {
                Label("Unassign", systemImage: "minus.circle")
            }
            .disabled(assignedCamera == nil)
            Divider()
            ForEach(cameraManager.cameras) { cam in
                Button {
                    cameraManager.setTslIndex(for: cam.id, index: source.umdID)
                } label: {
                    HStack {
                        Text(cam.name)
                        if cam.id == assignedCamera?.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let cam = assignedCamera {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.green)
                        .font(.system(size: 11))
                    Text(cam.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.label)
                } else {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(Theme.label3)
                        .font(.system(size: 11))
                    Text("Assign to camera")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.label2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.label3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.bgCardElevated, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Theme.label4, lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

// MARK: - Per-camera assignment row (the inverse view)

private struct CameraAssignmentRow: View {
    let camera: Camera
    @EnvironmentObject var cameraManager: CameraManager

    private var matchedSource: TSLDiscoveredID? {
        guard camera.tslIndex > 0 else { return nil }
        return cameraManager.discoveredTSLIDs[camera.tslIndex]
    }

    private var statusText: String {
        if camera.tslIndex == 0 { return "No filter set" }
        if matchedSource != nil { return "Receiving UMD \(camera.tslIndex)" }
        return "Filter UMD \(camera.tslIndex) — not in switcher stream"
    }
    private var statusIcon: String {
        if camera.tslIndex == 0 { return "circle.dashed" }
        if matchedSource != nil { return "checkmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }
    private var statusColor: Color {
        if camera.tslIndex == 0 { return Theme.label3 }
        if matchedSource != nil { return Theme.green }
        return Theme.yellow
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 13))
                .foregroundStyle(statusColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(camera.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.label)
                    Text(camera.ip)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.label3)
                }
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(matchedSource == nil && camera.tslIndex > 0 ? Theme.yellow : Theme.label2)
            }

            Spacer()

            if let src = matchedSource {
                HStack(spacing: 5) {
                    Circle()
                        .fill(src.isProgram ? Theme.red : (src.isPreview ? Theme.green : Theme.label3))
                        .frame(width: 7, height: 7)
                    Text(src.displayName.isEmpty ? "—" : src.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.label2)
                        .lineLimit(1)
                }
                .frame(maxWidth: 180, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
