import SwiftUI

struct TallySettingsView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @Environment(\.dismiss) var dismiss

    @State private var searchText = ""
    @State private var portText = ""

    var filteredCameras: [Camera] {
        if searchText.isEmpty {
            return cameraManager.cameras
        }
        return cameraManager.cameras.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Tally Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            // TSL Connection Status
            VStack(spacing: 12) {
                HStack {
                    // Three-state indicator
                    Circle()
                        .fill(tslStatusColor)
                        .frame(width: 8, height: 8)
                    Text("TSL")
                        .font(.caption)
                    Text(tslStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Toggle("Enable TSL", isOn: Binding(
                        get: { cameraManager.tslEnabled },
                        set: { enabled in
                            if enabled { cameraManager.startTSL() }
                            else { cameraManager.stopTSL() }
                        }
                    ))
                }

                HStack {
                    Text("TCP Port:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.center)
                        .onChange(of: portText) { newValue in
                            updatePort(newValue)
                        }
                    Spacer()
                }

                // LED brightness slider intentionally removed — the tally LEDs
                // are locked at 1 % so they never wash out talent's eyes on stage.
                // Boot default in the firmware sets the PWM to ~1 %; nothing
                // overrides it.

                HStack {
                    Toggle("Swap Program/Preview", isOn: $cameraManager.tslSwapProgramPreview)
                        .help("Enable if PVW shows as PGM (and vice versa) — for switchers like Ross Ultrix or Roland that invert the TSL T1/T2 bit assignment.")
                    Spacer()
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search cameras...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding()

            // Column headers
            HStack {
                Text("Camera")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Debug")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                    .frame(width: 16)
                Text("TSL Inputs")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                    .frame(width: 28)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            // Camera list
            List {
                ForEach(filteredCameras) { camera in
                    CameraTallyRow(camera: camera, cameraManager: cameraManager)
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 560, height: 620)
        .onAppear {
            portText = String(cameraManager.tslPort)
        }
    }

    private var tslStatusColor: Color {
        if cameraManager.tslClientConnected { return .green }
        if cameraManager.tslListening { return .yellow }
        return .gray
    }

    private var tslStatusText: String {
        if cameraManager.tslClientConnected { return "Switcher connected" }
        if cameraManager.tslListening { return "Listening on port \(cameraManager.tslPort)..." }
        return "Off"
    }

    private func updatePort(_ value: String) {
        guard let port = UInt16(value), port > 0, port <= 65535 else { return }
        guard port != cameraManager.tslPort else { return }  // no-op if port unchanged

        let wasEnabled = cameraManager.tslEnabled
        if wasEnabled { cameraManager.stopTSL() }
        cameraManager.tslPort = port
        UserDefaults.standard.set(Int(port), forKey: "tsl_port")
        if wasEnabled {
            cameraManager.startTSL()
            appLog("TSL listener restarted on port \(port)")
        } else {
            appLog("TSL port changed to \(port)")
        }
    }
}

// MARK: - Camera Row

struct CameraTallyRow: View {
    let camera: Camera
    let cameraManager: CameraManager

    @State private var showingPicker = false

    var selectedIndex: Int {
        cameraManager.cameras.first { $0.id == camera.id }?.tslIndex ?? 0
    }

    var assignmentLabel: String {
        selectedIndex == 0 ? "None" : "Input \(selectedIndex)"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Camera name + IP
            VStack(alignment: .leading, spacing: 2) {
                Text(camera.name)
                    .font(.headline)
                Text(camera.ip)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer()

            // Debug buttons
            HStack(spacing: 5) {
                Button(action: { sendDebugTally(program: true, preview: false) }) {
                    Text("PGM")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.red)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Set program (red) tally on this camera's ESP32")

                Button(action: { sendDebugTally(program: false, preview: true) }) {
                    Text("PVW")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.green)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Set preview (green) tally on this camera's ESP32")

                Button(action: { sendDebugTally(program: false, preview: false) }) {
                    Text("OFF")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlColor))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Clear tally on this camera's ESP32")
            }

            // TSL input picker button
            Button(action: { showingPicker = true }) {
                HStack(spacing: 5) {
                    Text(assignmentLabel)
                        .font(.caption)
                        .foregroundColor(selectedIndex == 0 ? .secondary : .primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(minWidth: 90)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPicker, arrowEdge: .trailing) {
                TSLIndexPicker(selectedIndex: Binding(
                    get: { selectedIndex },
                    set: { _ in /* updated via onPick below */ }
                ), onPick: { newIndex in
                    cameraManager.setTslIndex(for: camera.id, index: newIndex)
                    appLog("Updated TSL index for \(camera.name): \(newIndex)")
                })
            }

            // Live tally indicators
            HStack(spacing: 4) {
                if let state = cameraManager.cameraStates[camera.id] {
                    Circle()
                        .fill(state.tallyProgram ? Color.red : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(state.tallyPreview ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                } else {
                    Circle().fill(Color.gray.opacity(0.2)).frame(width: 10, height: 10)
                    Circle().fill(Color.gray.opacity(0.2)).frame(width: 10, height: 10)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func sendDebugTally(program: Bool, preview: Bool) {
        guard let state = cameraManager.cameraStates[camera.id] else {
            appLog("Debug tally: no state for \(camera.name)")
            return
        }
        let label = program ? "PROGRAM" : (preview ? "PREVIEW" : "OFF")
        appLog("Debug tally \(label) → \(camera.name)")
        state.updateTallyState(program: program, preview: preview)
    }
}

// MARK: - TSL Index Picker Popover

/// Single-index picker. Boards only ever apply one tally index, so the UI
/// matches: tap a row to select it (auto-dismisses the popover), or tap
/// "None" to clear. 0 means unassigned.
/// Picker that lists every UMD ID the switcher is currently sending, with the
/// switcher's own display name for that source. Operators pick from a real
/// list of what's on the wire instead of guessing numbers. Falls back to a
/// "Custom ID" stepper for cases where the box's source isn't currently
/// being sent (e.g. tally hasn't been cut to it yet).
struct TSLIndexPicker: View {
    @Binding var selectedIndex: Int
    var onPick: ((Int) -> Void)? = nil
    @EnvironmentObject var cameraManager: CameraManager
    @State private var search = ""
    @State private var customMode = false
    @State private var customIDDraft: Int = 1
    @Environment(\.dismiss) private var dismiss

    private var sortedDiscovered: [TSLDiscoveredID] {
        let entries = Array(cameraManager.discoveredTSLIDs.values)
            .sorted { $0.umdID < $1.umdID }
        if search.isEmpty { return entries }
        let q = search.lowercased()
        return entries.filter {
            $0.displayName.lowercased().contains(q) || String($0.umdID).contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    noneRow

                    if !sortedDiscovered.isEmpty {
                        Divider().padding(.leading, 12)
                        ForEach(sortedDiscovered) { entry in
                            discoveredRow(entry)
                            Divider().padding(.leading, 12)
                        }
                    } else {
                        emptyHint
                    }

                    customSection
                }
            }
        }
        .frame(width: 320, height: 400)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("Search by name or ID...", text: $search)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(cameraManager.tslClientConnected ? Color.success : Color(white: 0.5))
                    .frame(width: 6, height: 6)
                Text(cameraManager.tslClientConnected
                     ? "\(cameraManager.discoveredTSLIDs.count) source(s) live"
                     : (cameraManager.tslListening ? "Listening — no switcher connected" : "TSL off"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(10)
    }

    private var noneRow: some View {
        Button { pick(0) } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedIndex == 0 ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selectedIndex == 0 ? .accentColor : Color(NSColor.tertiaryLabelColor))
                    .font(.system(size: 15))
                Text("None — don't react to any TSL")
                    .foregroundColor(.primary)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selectedIndex == 0 ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func discoveredRow(_ entry: TSLDiscoveredID) -> some View {
        Button { pick(entry.umdID) } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedIndex == entry.umdID ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selectedIndex == entry.umdID ? .accentColor : Color(NSColor.tertiaryLabelColor))
                    .font(.system(size: 15))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // Live tally indicator dot
                        Circle()
                            .fill(tallyColor(entry))
                            .frame(width: 7, height: 7)
                        Text(entry.displayName.isEmpty ? "ID \(entry.umdID)" : entry.displayName)
                            .foregroundColor(.primary)
                            .font(.callout)
                    }
                    HStack(spacing: 6) {
                        Text("UMD \(entry.umdID)")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        Text("·")
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        Text("\(entry.packetCount) pkts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selectedIndex == entry.umdID ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No UMD IDs discovered yet")
                .font(.callout)
                .foregroundColor(.secondary)
            Text("Cut to each camera on the switcher one at a time. IDs will appear here as the dashboard sees them on the TSL stream.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var customSection: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                customMode.toggle()
                if customMode {
                    customIDDraft = selectedIndex > 0 ? selectedIndex : 1
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "pencil")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                    Text(customMode ? "Hide custom ID" : "Enter ID manually...")
                        .foregroundColor(.primary)
                        .font(.callout)
                    Spacer()
                    Image(systemName: customMode ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            if customMode {
                HStack(spacing: 8) {
                    Stepper(value: $customIDDraft, in: 1...65535) {
                        TextField("ID", value: $customIDDraft, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .font(.callout.monospaced())
                    }
                    Button("Set") { pick(customIDDraft) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    // MARK: - Helpers

    private func tallyColor(_ entry: TSLDiscoveredID) -> Color {
        if entry.isProgram { return .error }
        if entry.isPreview { return .success }
        return Color(white: 0.35)
    }

    private func pick(_ index: Int) {
        selectedIndex = index
        onPick?(index)
        dismiss()
    }
}

#Preview {
    TallySettingsView()
        .environmentObject(CameraManager())
}
