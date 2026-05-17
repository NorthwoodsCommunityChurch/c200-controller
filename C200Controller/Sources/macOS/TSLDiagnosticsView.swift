import SwiftUI

/// Comprehensive TSL diagnostics — everything needed to verify the
/// Carbonite → TCP → parser → filter → LED chain end to end without
/// dropping to the command line. Three panels:
///   1. Dashboard's own TSL listener status + discovered UMD sources
///   2. Per-box chain status (Carbonite session, packet counts, mismatches)
///   3. Quick actions (clear discovery, refresh all)
struct TSLDiagnosticsView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    listenerSection
                    discoveredSection
                    perBoxSection
                }
                .padding(16)
            }
        }
        .frame(minWidth: 760, minHeight: 600)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("TSL Status")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("Refresh All Boxes") {
                Task {
                    for cam in cameraManager.cameras
                        where cam.connectionType == .esp32 {
                        try? await cameraManager.cameraStates[cam.id]?.refreshStatusForDiagnostics()
                    }
                }
            }
            .help("Force-fetch /api/status from every box right now")
            Button("Done") { dismiss() }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Listener section

    private var listenerSection: some View {
        panelSection("Switcher → Dashboard") {
            HStack(alignment: .top, spacing: 24) {
                statRow(label: "Listener",
                        value: cameraManager.tslListening ? "ready" : "off",
                        color: cameraManager.tslListening ? .success : Color(white: 0.4))
                statRow(label: "Switcher",
                        value: cameraManager.tslClientConnected ? "connected" : "not connected",
                        color: cameraManager.tslClientConnected ? .success : Color(white: 0.4))
                statRow(label: "Port",
                        value: "\(cameraManager.tslPort)")
                statRow(label: "Unique IDs seen",
                        value: "\(cameraManager.discoveredTSLIDs.count)")
                Spacer()
            }
        }
    }

    // MARK: - Discovered UMD sources

    private var discoveredSection: some View {
        let sorted = cameraManager.discoveredTSLIDs.values.sorted { $0.umdID < $1.umdID }
        return panelSection("Discovered UMD Sources") {
            if sorted.isEmpty {
                emptyHint(cameraManager.tslListening
                          ? (cameraManager.tslClientConnected
                             ? "Switcher is connected but hasn't sent any UMD packets yet."
                             : "Listener is up — waiting for a switcher to connect on port \(cameraManager.tslPort).")
                          : "TSL listener is off. Turn it on in Tally Settings.")
            } else {
                VStack(spacing: 0) {
                    discoveredHeaderRow
                    Divider()
                    ForEach(sorted) { entry in
                        discoveredRow(entry)
                        Divider()
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var discoveredHeaderRow: some View {
        HStack(spacing: 12) {
            columnHeader("UMD ID", width: 80)
            columnHeader("Name", width: 200)
            columnHeader("Live", width: 90)
            columnHeader("Packets", width: 90)
            columnHeader("Last seen", width: 90)
            Spacer()
            columnHeader("Assigned to box", width: 220)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func discoveredRow(_ entry: TSLDiscoveredID) -> some View {
        let assignedCameras = cameraManager.cameras.filter { $0.tslIndex == entry.umdID }
        let lastSeenAgo = ageString(Date().timeIntervalSince(entry.lastSeen))
        return HStack(spacing: 12) {
            Text("\(entry.umdID)")
                .font(.body.monospaced())
                .frame(width: 80, alignment: .leading)
            Text(entry.displayName.isEmpty ? "—" : entry.displayName)
                .font(.body)
                .frame(width: 200, alignment: .leading)
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle()
                    .fill(entry.isProgram ? Color.error : (entry.isPreview ? Color.success : Color(white: 0.4)))
                    .frame(width: 8, height: 8)
                Text(entry.isProgram ? "PGM" : (entry.isPreview ? "PVW" : "off"))
                    .font(.caption.monospaced())
                    .foregroundColor(entry.isProgram ? .error
                                     : (entry.isPreview ? .success : .secondary))
            }
            .frame(width: 90, alignment: .leading)
            Text("\(entry.packetCount)")
                .font(.body.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(lastSeenAgo)
                .font(.body.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Spacer()
            if assignedCameras.isEmpty {
                Text("not assigned")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 220, alignment: .leading)
            } else {
                Text(assignedCameras.map(\.name).joined(separator: ", "))
                    .font(.body)
                    .foregroundColor(.accentColor)
                    .frame(width: 220, alignment: .leading)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Per-box section

    private var perBoxSection: some View {
        panelSection("Per-Box Receiver Chain") {
            VStack(spacing: 0) {
                boxHeaderRow
                Divider()
                ForEach(cameraManager.cameras.filter { $0.connectionType == .esp32 }) { camera in
                    if let state = cameraManager.cameraStates[camera.id] {
                        BoxDiagnosticsRow(camera: camera, state: state, manager: cameraManager)
                        Divider()
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var boxHeaderRow: some View {
        HStack(spacing: 12) {
            columnHeader("Camera", width: 100)
            columnHeader("IP", width: 110)
            columnHeader("Carb→box", width: 100)
            columnHeader("Filter ID", width: 70)
            columnHeader("Matched", width: 90)
            columnHeader("Total", width: 80)
            columnHeader("Last ID", width: 80)
            columnHeader("Last state", width: 90)
            Spacer()
            columnHeader("Issue", width: 200)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func panelSection<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.5)
                .foregroundColor(.secondary)
            content()
        }
    }

    private func statRow(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body.weight(.medium))
                .foregroundColor(color)
        }
    }

    private func columnHeader(_ title: String, width: CGFloat) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.4)
            .foregroundColor(.secondary)
            .frame(width: width, alignment: .leading)
    }

    private func emptyHint(_ msg: String) -> some View {
        Text(msg)
            .font(.callout)
            .foregroundColor(.secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
    }

    private func ageString(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds/60))m ago" }
        return ">1h ago"
    }
}

// MARK: - Per-box row (separate type so it can @ObservedObject the state)

struct BoxDiagnosticsRow: View {
    let camera: Camera
    @ObservedObject var state: CameraState
    let manager: CameraManager

    private var issue: String? {
        if camera.tslIndex == 0 { return "No filter ID assigned" }
        if !state.tslClientConnected { return "Carbonite not connected to this box" }
        if state.tslLastIndexSeen > 0 && state.tslLastIndexSeen != camera.tslIndex {
            return "Filter \(camera.tslIndex) but Carbonite sends \(state.tslLastIndexSeen)"
        }
        if state.tslPacketsTotal > 100 && state.tslPacketsMatched == 0 {
            return "Receiving \(state.tslPacketsTotal) packets, none match"
        }
        return nil
    }

    private var lastStateColor: Color {
        switch state.tslLastState {
        case "program": return .error
        case "preview": return .success
        case "both":    return .warning
        default:        return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(camera.name)
                .font(.body.weight(.medium))
                .frame(width: 100, alignment: .leading)
            Text(camera.ip)
                .font(.body.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            HStack(spacing: 4) {
                Circle()
                    .fill(state.tslClientConnected ? Color.success : Color(white: 0.4))
                    .frame(width: 8, height: 8)
                Text(state.tslClientConnected ? "yes" : "no")
                    .font(.body)
                    .foregroundColor(state.tslClientConnected ? .success : .secondary)
            }
            .frame(width: 100, alignment: .leading)
            Text(camera.tslIndex == 0 ? "—" : "\(camera.tslIndex)")
                .font(.body.monospaced())
                .frame(width: 70, alignment: .leading)
            Text("\(state.tslPacketsMatched)")
                .font(.body.monospaced())
                .frame(width: 90, alignment: .leading)
            Text("\(state.tslPacketsTotal)")
                .font(.body.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(state.tslLastIndexSeen == 0 ? "—" : "\(state.tslLastIndexSeen)")
                .font(.body.monospaced())
                .foregroundColor(issue?.contains("Carbonite sends") == true ? .error : .primary)
                .frame(width: 80, alignment: .leading)
            Text(state.tslLastState)
                .font(.body.monospaced())
                .foregroundColor(lastStateColor)
                .frame(width: 90, alignment: .leading)
            Spacer()
            if let issue = issue {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.error)
                        .font(.caption)
                    Text(issue)
                        .font(.caption)
                        .foregroundColor(.error)
                        .lineLimit(2)
                }
                .frame(width: 200, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.success)
                        .font(.caption)
                    Text("OK")
                        .font(.caption)
                        .foregroundColor(.success)
                }
                .frame(width: 200, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
