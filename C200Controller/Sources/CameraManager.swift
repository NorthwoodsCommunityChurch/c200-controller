import Foundation
import Network
import Combine

/// Manages multiple cameras with auto-discovery and persistence
@MainActor
class CameraManager: ObservableObject {
    // All known cameras (persisted)
    @Published var cameras: [Camera] = []

    // Active camera states (one per camera)
    @Published var cameraStates: [String: CameraState] = [:]

    // Discovery state
    @Published var isScanning = false
    @Published var discoveredESP32s: [DiscoveredESP32] = []

    // Manual connection UI state
    @Published var manualESP32IP = ""
    @Published var manualCameraIP = ""

    // Auto-reconnect setting
    @Published var autoReconnect: Bool {
        didSet {
            UserDefaults.standard.set(autoReconnect, forKey: autoReconnectKey)
            // Update all camera states
            for (_, state) in cameraStates {
                state.autoReconnectEnabled = autoReconnect
            }
        }
    }

    // TSL tally support
    @Published var tslEnabled = false
    @Published var tslPort: UInt16 = 5201
    @Published var tslListening = false       // port is bound and accepting
    @Published var tslClientConnected = false // a switcher is actively connected
    private var tslClient: TSLClient?

    // Camera Positions integration
    @Published var positionsEnabled = false
    @Published var positionsHost = ""
    @Published var positionsPort: Int = 8765
    @Published var positionsAssignments: [Int: CameraAssignment] = [:]
    private var positionsClient: CameraPositionsClient?

    private var browser: NWBrowser?
    private let persistenceKey = "known_cameras_v2"
    private let autoReconnectKey = "auto_reconnect_enabled"

    struct DiscoveredESP32: Identifiable {
        let id: String          // MAC address
        let name: String        // mDNS name
        let ip: String
    }

    init() {
        // Load auto-reconnect setting
        self.autoReconnect = UserDefaults.standard.bool(forKey: autoReconnectKey)

        // Restore TSL settings
        tslEnabled = UserDefaults.standard.bool(forKey: "tsl_enabled")
        let savedPort = UserDefaults.standard.integer(forKey: "tsl_port")
        if savedPort > 0 && savedPort <= 65535 {
            tslPort = UInt16(savedPort)
        }

        loadCameras()
        startBonjourDiscovery()
        connectAllCameras()

        // Start TSL listener if enabled — delayed so the network stack is ready
        if tslEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startTSL()
            }
        }

        // Restore Camera Positions settings
        positionsEnabled = UserDefaults.standard.bool(forKey: "positions_enabled")
        positionsHost = UserDefaults.standard.string(forKey: "positions_host") ?? ""
        let savedPositionsPort = UserDefaults.standard.integer(forKey: "positions_port")
        if savedPositionsPort > 0 { positionsPort = savedPositionsPort }

        if positionsEnabled && !positionsHost.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startPositions()
            }
        }
    }

    deinit {
        browser?.cancel()
    }

    // MARK: - Persistence

    private func loadCameras() {
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode([Camera].self, from: data) {
            cameras = decoded
            print("Loaded \(cameras.count) cameras from storage")
        }
    }

    func saveCameras() {
        if let data = try? JSONEncoder().encode(cameras) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
            print("Saved \(cameras.count) cameras to storage")
        }
    }

    // MARK: - Camera Management

    func addCamera(_ camera: Camera) {
        // Don't add duplicates
        guard !cameras.contains(where: { $0.id == camera.id }) else {
            // Update IP if changed
            if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
                cameras[index].ip = camera.ip
                saveCameras()
            }
            return
        }

        cameras.append(camera)
        saveCameras()

        // Create state and connect
        let state = CameraState(camera: camera)
        cameraStates[camera.id] = state
        Task {
            await state.connect()
        }
    }

    func removeCamera(_ camera: Camera) {
        // Disconnect first
        cameraStates[camera.id]?.disconnect()
        cameraStates.removeValue(forKey: camera.id)

        // Remove from list
        cameras.removeAll { $0.id == camera.id }
        saveCameras()
    }

    func renameCamera(_ camera: Camera, to newName: String) {
        if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras[index].name = newName
            saveCameras()
        }
    }

    func getState(for camera: Camera) -> CameraState? {
        return cameraStates[camera.id]
    }

    private func connectAllCameras() {
        for camera in cameras {
            let state = CameraState(camera: camera)
            state.autoReconnectEnabled = autoReconnect
            cameraStates[camera.id] = state
            Task {
                await state.connect()
            }
        }
    }

    // MARK: - Manual Connection

    func addESP32Manually(ip: String) {
        guard !ip.isEmpty else { return }

        Task {
            // Try to fetch status to get the ESP ID
            let url = URL(string: "http://\(ip)/api/status")!
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: config)

            do {
                let (data, _) = try await session.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let espId = json["esp_id"] as? String {
                    let name = json["esp_name"] as? String ?? "ESP32"
                    let camera = Camera(
                        id: espId,
                        name: name,
                        ip: ip,
                        connectionType: .esp32,
                        isAutoDiscovered: false
                    )
                    await MainActor.run {
                        addCamera(camera)
                    }
                }
            } catch {
                print("Failed to connect to ESP32 at \(ip): \(error)")
            }
        }
    }

    func addDirectCamera(ip: String) {
        guard !ip.isEmpty else { return }

        let camera = Camera(
            id: "direct-\(ip)",
            name: "Canon C200",
            ip: ip,
            connectionType: .direct,
            isAutoDiscovered: false
        )
        addCamera(camera)
    }

    // MARK: - Bonjour Discovery

    func startBonjourDiscovery() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        browser = NWBrowser(for: .bonjour(type: "_http._tcp.", domain: nil), using: parameters)

        browser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isScanning = true
                case .failed, .cancelled:
                    self?.isScanning = false
                default:
                    break
                }
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                self?.handleBrowseResults(results)
            }
        }

        browser?.start(queue: .main)
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            switch result.endpoint {
            case .service(let name, let type, let domain, _):
                // Filter for C200/ESP32 controllers
                if name.lowercased().contains("c200") || name.lowercased().contains("esp32") {
                    resolveService(name: name, type: type, domain: domain)
                }
            default:
                break
            }
        }
    }

    private func resolveService(name: String, type: String, domain: String) {
        let parameters = NWParameters.tcp
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, _) = innerEndpoint {
                    let ip = "\(host)"
                        .replacingOccurrences(of: "%.*$", with: "", options: .regularExpression)

                    Task { @MainActor [weak self] in
                        self?.fetchESP32Info(name: name, ip: ip)
                    }
                }
                connection.cancel()
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global())
    }

    private func fetchESP32Info(name: String, ip: String) {
        Task {
            let url = URL(string: "http://\(ip)/api/status")!
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 3
            let session = URLSession(configuration: config)

            do {
                let (data, _) = try await session.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let espId = json["esp_id"] as? String {
                    let espName = json["esp_name"] as? String ?? name

                    // Check if already in discovered list
                    if !discoveredESP32s.contains(where: { $0.id == espId }) {
                        let discovered = DiscoveredESP32(id: espId, name: espName, ip: ip)
                        await MainActor.run {
                            discoveredESP32s.append(discovered)
                        }
                    }

                    // Check if camera already exists (preserve custom name)
                    if let existingIndex = cameras.firstIndex(where: { $0.id == espId }) {
                        // Camera exists - only update IP if changed, keep custom name
                        await MainActor.run {
                            if cameras[existingIndex].ip != ip {
                                cameras[existingIndex].ip = ip
                                saveCameras()
                                print("Updated IP for \(cameras[existingIndex].name): \(ip)")

                                // Reconnect with new IP
                                if let state = cameraStates[espId] {
                                    state.disconnect()
                                }
                                let updatedCamera = cameras[existingIndex]
                                let state = CameraState(camera: updatedCamera)
                                cameraStates[espId] = state
                                Task {
                                    await state.connect()
                                }
                            }
                        }
                    } else {
                        // New camera - add with ESP32's default name
                        let camera = Camera(
                            id: espId,
                            name: espName,
                            ip: ip,
                            connectionType: .esp32,
                            isAutoDiscovered: true
                        )
                        await MainActor.run {
                            addCamera(camera)
                            print("Added new camera: \(espName) at \(ip)")
                        }
                    }
                }
            } catch {
                print("Failed to fetch ESP32 info from \(ip): \(error)")
            }
        }
    }

    func refreshDiscovery() {
        discoveredESP32s.removeAll()
        browser?.cancel()
        startBonjourDiscovery()
    }

    // MARK: - TSL Tally Integration

    func startTSL() {
        guard tslClient == nil else { return }

        tslClient = TSLClient(host: "", port: tslPort)

        tslClient?.onConnectionChange = { [weak self] listening in
            Task { @MainActor in
                self?.tslListening = listening
                if !listening { self?.tslClientConnected = false }
                appLog("TSL listener \(listening ? "ready" : "stopped")")
            }
        }

        tslClient?.onClientConnected = { [weak self] in
            Task { @MainActor in
                self?.tslClientConnected = true
                appLog("TSL: switcher connected")
            }
        }

        tslClient?.onClientDisconnected = { [weak self] in
            Task { @MainActor in
                self?.tslClientConnected = false
                appLog("TSL: switcher disconnected")
            }
        }

        tslClient?.onTallyUpdate = { [weak self] index, isProgram, isPreview in
            Task { @MainActor in
                self?.handleTallyUpdate(index: index, isProgram: isProgram, isPreview: isPreview)
            }
        }

        tslClient?.connect()
        tslEnabled = true
        UserDefaults.standard.set(true, forKey: "tsl_enabled")
        UserDefaults.standard.set(Int(tslPort), forKey: "tsl_port")
    }

    func stopTSL() {
        tslClient?.disconnect()
        tslClient = nil
        tslEnabled = false
        tslListening = false
        tslClientConnected = false
        UserDefaults.standard.set(false, forKey: "tsl_enabled")
    }

    private func handleTallyUpdate(index: Int, isProgram: Bool, isPreview: Bool) {
        // Find cameras with this TSL index in their assigned indices
        let matchingCameras = cameras.filter { $0.tslIndices.contains(index) }

        guard !matchingCameras.isEmpty else { return }

        appLog("TSL update: index=\(index), program=\(isProgram), preview=\(isPreview) → \(matchingCameras.count) camera(s)")

        // Update all matching cameras
        for camera in matchingCameras {
            if let state = cameraStates[camera.id] {
                Task {
                    await state.updateTallyState(program: isProgram, preview: isPreview)
                }
            }
        }
    }

    // MARK: - Camera Positions Integration

    func startPositions() {
        guard positionsClient == nil else { return }
        guard !positionsHost.isEmpty else { return }

        positionsClient = CameraPositionsClient()
        positionsClient?.onAssignmentsUpdate = { [weak self] assignments in
            self?.positionsAssignments = assignments
        }
        positionsClient?.start(host: positionsHost, port: positionsPort)
        positionsEnabled = true
        UserDefaults.standard.set(true, forKey: "positions_enabled")
        UserDefaults.standard.set(positionsHost, forKey: "positions_host")
        UserDefaults.standard.set(positionsPort, forKey: "positions_port")
    }

    func stopPositions() {
        positionsClient?.stop()
        positionsClient = nil
        positionsEnabled = false
        positionsAssignments = [:]
        UserDefaults.standard.set(false, forKey: "positions_enabled")
    }
}
