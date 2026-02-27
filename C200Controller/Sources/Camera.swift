import Foundation
import Combine


/// Represents a camera connection (either via ESP32 bridge or direct)
struct Camera: Identifiable, Codable, Equatable {
    let id: String              // ESP32 MAC address or "direct-{ip}"
    var name: String            // User-friendly name (e.g., "Camera 1")
    var ip: String              // Current IP address
    var connectionType: ConnectionType
    var isAutoDiscovered: Bool  // True if found via Bonjour
    var tslIndices: [Int] = []  // TSL display indices (1-based) for tally assignment
    var positionsNumber: Int? = nil  // Camera Position # for Camera Positions integration

    enum ConnectionType: String, Codable {
        case esp32
        case direct
    }

    init(id: String, name: String, ip: String, connectionType: ConnectionType,
         isAutoDiscovered: Bool, tslIndices: [Int] = [], positionsNumber: Int? = nil) {
        self.id = id
        self.name = name
        self.ip = ip
        self.connectionType = connectionType
        self.isAutoDiscovered = isAutoDiscovered
        self.tslIndices = tslIndices
        self.positionsNumber = positionsNumber
    }

    // Separate key enum for legacy migration (decoder only)
    private enum LegacyKeys: String, CodingKey { case tslIndex }

    // Custom decoder: migrates old tslIndex (Int?) to tslIndices ([Int])
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        ip = try c.decode(String.self, forKey: .ip)
        connectionType = try c.decode(ConnectionType.self, forKey: .connectionType)
        isAutoDiscovered = try c.decode(Bool.self, forKey: .isAutoDiscovered)
        if let indices = try? c.decode([Int].self, forKey: .tslIndices) {
            tslIndices = indices
        } else {
            // Migrate from old single-index format
            let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            if let single = try? legacy?.decode(Int.self, forKey: .tslIndex) {
                tslIndices = [single]
            } else {
                tslIndices = []
            }
        }
        positionsNumber = try? c.decode(Int.self, forKey: .positionsNumber)
    }

    static func == (lhs: Camera, rhs: Camera) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.ip == rhs.ip &&
        lhs.connectionType == rhs.connectionType &&
        lhs.tslIndices == rhs.tslIndices &&
        lhs.positionsNumber == rhs.positionsNumber
    }
}

/// Observable state for a single camera
@MainActor
class CameraState: ObservableObject, @preconcurrency Identifiable {
    let camera: Camera

    var id: String { camera.id }

    // Connection state
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var connectionError: String?
    @Published var esp32Reachable = false

    // ESP32 state (only for ESP32 connections)
    @Published var wifiConnected = false
    @Published var ethConnected = false

    // Camera state
    @Published var isRecording = false
    @Published var aperture = "--"
    @Published var iso = "--"
    @Published var shutter = "--"
    @Published var aeShift = "--"
    @Published var ndFilter = "--"
    @Published var wbMode = "--"
    @Published var wbKelvin = "--"
    @Published var afMode = "--"
    @Published var faceDetect = "--"

    // Firmware version (ESP32 only)
    @Published var firmwareVersion = "--"

    // Tally state
    @Published var tallyProgram = false
    @Published var tallyPreview = false

    // Command state
    @Published var isCommandPending = false

    // Auto-reconnect
    @Published var isReconnecting = false
    var autoReconnectEnabled = false
    private var reconnectTimer: Timer?

    // Called by CameraManager when this camera successfully connects
    var onConnected: (() -> Void)?

    // Networking
    private var pollTimer: Timer?
    private var isDirectPolling = false
    private var webSocketTask: URLSessionWebSocketTask?
    private var webSocketReconnectTask: Task<Void, Never>?
    private let session: URLSession
    private var cameraCookies: String = ""
    private var cameraUsername = "admin"
    private var cameraPassword = "admin"

    init(camera: Camera) {
        self.camera = camera

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    deinit {
        pollTimer?.invalidate()
        reconnectTimer?.invalidate()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketReconnectTask?.cancel()
    }

    // MARK: - Connection

    func connect() async {
        guard !isConnecting else { return }

        await MainActor.run {
            isConnecting = true
            isReconnecting = false
            connectionError = nil
            reconnectTimer?.invalidate()
            reconnectTimer = nil
        }

        do {
            switch camera.connectionType {
            case .esp32:
                let success = try await connectToESP32()
                await MainActor.run {
                    isConnected = success
                    if success {
                        startPolling()
                        // Restore saved brightness on connect
                        let savedPct = UserDefaults.standard.integer(forKey: "tally_brightness")
                        let pct = savedPct == 0 ? 100 : savedPct
                        let esp32Value = Int(Double(pct) / 100.0 * 255.0)
                        Task { await self.sendBrightness(esp32Value) }
                        onConnected?()
                    } else {
                        scheduleReconnectIfEnabled()
                    }
                }
            case .direct:
                let success = try await connectDirectToCamera()
                await MainActor.run {
                    isConnected = success
                    if success {
                        startDirectPolling()
                    } else {
                        scheduleReconnectIfEnabled()
                    }
                }
            }
        } catch {
            await MainActor.run {
                connectionError = friendlyError(error)
                isConnected = false
                scheduleReconnectIfEnabled()
            }
        }

        await MainActor.run {
            isConnecting = false
        }
    }

    private func scheduleReconnectIfEnabled() {
        guard autoReconnectEnabled else { return }

        reconnectTimer?.invalidate()
        isReconnecting = true

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if !self.isConnected && self.autoReconnectEnabled {
                    print("Auto-reconnecting to \(self.camera.name)...")
                    await self.connect()
                }
            }
        }
    }

    func stopAutoReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        isReconnecting = false
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        isDirectPolling = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        webSocketReconnectTask?.cancel()
        webSocketReconnectTask = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        isConnected = false
        isReconnecting = false
        esp32Reachable = false
        cameraCookies = ""
    }

    // MARK: - Helpers

    private func friendlyError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:              return "Connection timed out"
            case .cannotConnectToHost:   return "Cannot reach ESP32"
            case .networkConnectionLost: return "Connection lost"
            case .notConnectedToInternet: return "No network"
            case .cannotFindHost:        return "Host not found"
            default:                     return "Connection failed"
            }
        }
        return "Connection failed"
    }

    // MARK: - ESP32 Connection

    private func connectToESP32() async throws -> Bool {
        let url = URL(string: "http://\(camera.ip)/api/status")!
        let (data, _) = try await session.data(from: url)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        await MainActor.run {
            self.esp32Reachable = true
            self.wifiConnected = json["wifi_connected"] as? Bool ?? false
            self.ethConnected = json["eth_connected"] as? Bool ?? false
            self.isRecording = json["is_recording"] as? Bool ?? false
        }

        return json["camera_connected"] as? Bool ?? false
    }

    private func startPolling() {
        // Fetch initial state, then start WebSocket for fast updates
        Task {
            try? await fetchESP32Status()
            try? await fetchESP32CameraState()
        }
        startWebSocket()
    }

    // MARK: - WebSocket (ESP32 push updates)

    private func startWebSocket() {
        webSocketReconnectTask?.cancel()
        webSocketReconnectTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)

        guard let url = URL(string: "ws://\(camera.ip)/ws") else { return }
        appLog("WS connecting to \(camera.name) at \(camera.ip)")
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveWebSocketMessage()
    }

    private func receiveWebSocketMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    Task { await self.handleWebSocketUpdate(text) }
                }
                self.receiveWebSocketMessage()
            case .failure:
                Task { @MainActor [weak self] in self?.esp32Reachable = false }
                // Reconnect after 3 seconds
                self.webSocketReconnectTask = Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    appLog("WS reconnecting to \(self.camera.name)...")
                    self.startWebSocket()
                }
            }
        }
    }

    @MainActor
    private func handleWebSocketUpdate(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let isoVal = (json["gcv"] as? [String: Any])?["value"] as? String ?? "?"
        appLog("WS \(camera.name): iso=\(isoVal)")

        esp32Reachable = true

        // Status
        isConnected = json["camera_connected"] as? Bool ?? false
        isRecording = json["recording"] as? Bool ?? false
        wifiConnected = json["wifi_connected"] as? Bool ?? false
        ethConnected = json["eth_connected"] as? Bool ?? false

        // Camera state (same keys as fetchESP32CameraState)
        if let av   = json["av"]   as? [String: Any] { aperture  = av["value"]   as? String ?? "--" }
        if let gcv  = json["gcv"]  as? [String: Any] { iso       = gcv["value"]  as? String ?? "--" }
        if let ssv  = json["ssv"]  as? [String: Any] { shutter   = ssv["value"]  as? String ?? "--" }
        if let aesv = json["aesv"] as? [String: Any] { aeShift   = aesv["value"] as? String ?? "--" }
        if let ndv  = json["ndv"]  as? [String: Any] { ndFilter  = ndv["value"]  as? String ?? "--" }
        if let wbm  = json["wbm"]  as? [String: Any] { wbMode    = wbm["value"]  as? String ?? "--" }
        if let wbvk = json["wbvk"] as? [String: Any] {
            if let k = wbvk["value"] as? String { wbKelvin = k + "K" }
        }
        if let afm  = json["afm"]  as? [String: Any] { afMode    = afm["value"]  as? String ?? "--" }

        // Parse tally state from ESP32
        if let tallyStr = json["tally"] as? String {
            tallyProgram = (tallyStr == "program" || tallyStr == "both")
            tallyPreview = (tallyStr == "preview" || tallyStr == "both")
        }
    }

    private func fetchESP32Status() async throws {
        let url = URL(string: "http://\(camera.ip)/api/status")!
        let (data, _) = try await session.data(from: url)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        await MainActor.run {
            self.esp32Reachable = true
            self.wifiConnected = json["wifi_connected"] as? Bool ?? false
            self.ethConnected = json["eth_connected"] as? Bool ?? false
            self.isConnected = json["camera_connected"] as? Bool ?? false
            self.isRecording = json["is_recording"] as? Bool ?? false
            if let fw = json["firmware_version"] as? String {
                self.firmwareVersion = fw
            }
        }
    }

    private func fetchESP32CameraState() async throws {
        let url = URL(string: "http://\(camera.ip)/api/camera/state")!
        let (data, _) = try await session.data(from: url)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        await MainActor.run {
            if let av = json["av"] as? [String: Any] {
                self.aperture = av["value"] as? String ?? "--"
            }
            if let gcv = json["gcv"] as? [String: Any] {
                self.iso = gcv["value"] as? String ?? "--"
            }
            if let ssv = json["ssv"] as? [String: Any] {
                self.shutter = ssv["value"] as? String ?? "--"
            }
            if let aesv = json["aesv"] as? [String: Any] {
                self.aeShift = aesv["value"] as? String ?? "--"
            }
            if let ndv = json["ndv"] as? [String: Any] {
                self.ndFilter = ndv["value"] as? String ?? "--"
            }
            if let wbm = json["wbm"] as? [String: Any] {
                self.wbMode = wbm["value"] as? String ?? "--"
            }
            if let wbvk = json["wbvk"] as? [String: Any] {
                if let k = wbvk["value"] as? String {
                    self.wbKelvin = k + "K"
                }
            }
            if let afm = json["afm"] as? [String: Any] {
                self.afMode = afm["value"] as? String ?? "--"
            }
        }
    }

    // MARK: - Direct Camera Connection

    private func connectDirectToCamera() async throws -> Bool {
        let url = URL(string: "http://\(camera.ip)/api/acnt/login")!
        var request = URLRequest(url: url)

        let credentials = "\(cameraUsername):\(cameraPassword)"
        if let credentialsData = credentials.data(using: .utf8) {
            let base64Credentials = credentialsData.base64EncodedString()
            request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        // Extract cookies
        if let httpResponse = response as? HTTPURLResponse {
            var cookies: [String] = []
            if let allHeaders = httpResponse.allHeaderFields as? [String: Any] {
                for (key, value) in allHeaders {
                    if key.lowercased() == "set-cookie" {
                        if let cookieString = value as? String {
                            let parts = cookieString.split(separator: ";")
                            if let cookieValue = parts.first {
                                cookies.append(String(cookieValue))
                            }
                        }
                    }
                }
            }
            cameraCookies = cookies.joined(separator: "; ")
            if !cameraCookies.isEmpty {
                cameraCookies += "; brlang=0; productId=VNCX02"
            } else {
                cameraCookies = "brlang=0; productId=VNCX02"
            }
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let res = json["res"] as? String, res == "ok" {
            // Start LV session
            _ = try? await makeDirectRequest(path: "/api/cam/lv?cmd=start&sz=s")
            return true
        }

        return false
    }

    private func startDirectPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isDirectPolling else { return }
                self.isDirectPolling = true
                try? await self.fetchDirectCameraState()
                try? await self.fetchDirectRecordingState()
                self.isDirectPolling = false
            }
        }

        Task {
            try? await fetchDirectCameraState()
            try? await fetchDirectRecordingState()
        }
    }

    private func makeDirectRequest(path: String) async throws -> Data {
        let url = URL(string: "http://\(camera.ip)\(path)")!
        var request = URLRequest(url: url)

        let credentials = "\(cameraUsername):\(cameraPassword)"
        if let credentialsData = credentials.data(using: .utf8) {
            let base64Credentials = credentialsData.base64EncodedString()
            request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
        }

        if !cameraCookies.isEmpty {
            request.setValue(cameraCookies, forHTTPHeaderField: "Cookie")
        }

        let (data, _) = try await session.data(for: request)
        return data
    }

    private func fetchDirectCameraState() async throws {
        let properties = ["av", "gcv", "ssv", "ndv", "wbm", "wbvk", "aesv", "afm"]

        for prop in properties {
            do {
                let data = try await makeDirectRequest(path: "/api/cam/getprop?r=\(prop)")

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let res = json["res"] as? String, res == "errsession" {
                        _ = try? await connectDirectToCamera()
                        return
                    }

                    let key = "O\(prop)"
                    if let propObj = json[key] as? [String: Any],
                       let pv = propObj["pv"] {
                        await MainActor.run {
                            let value: String
                            if let stringVal = pv as? String {
                                value = stringVal
                            } else if let numVal = pv as? Double {
                                value = numVal == floor(numVal) ? String(Int(numVal)) : String(format: "%.2f", numVal)
                            } else {
                                value = "--"
                            }

                            switch prop {
                            case "av": self.aperture = value
                            case "gcv": self.iso = value
                            case "ssv": self.shutter = value
                            case "ndv": self.ndFilter = value
                            case "wbm": self.wbMode = value
                            case "wbvk": self.wbKelvin = value + "K"
                            case "aesv": self.aeShift = value
                            case "afm": self.afMode = value
                            default: break
                            }
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                print("Error fetching \(prop): \(error)")
            }
        }
    }

    private func fetchDirectRecordingState() async throws {
        let data = try await makeDirectRequest(path: "/api/cam/getcurprop?seq=0")

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rec = json["rec"] as? String {
            let recording = rec == "rec"
            await MainActor.run {
                self.isRecording = recording
            }
        }
    }

    // MARK: - Commands

    func sendCommand(_ control: String, _ direction: String) {
        guard !isCommandPending else { return }

        Task {
            await MainActor.run { isCommandPending = true }

            do {
                switch camera.connectionType {
                case .esp32:
                    var request = URLRequest(url: URL(string: "http://\(camera.ip)/api/camera/\(control)/\(direction)")!)
                    request.httpMethod = "POST"
                    _ = try await session.data(for: request)
                    // WebSocket push handles the state update automatically

                case .direct:
                    let cameraParam: String
                    switch control {
                    case "iris": cameraParam = "iris"
                    case "iso": cameraParam = "iso"
                    case "shutter": cameraParam = "shutter"
                    case "nd": cameraParam = "nd"
                    case "aes": cameraParam = "aes"
                    case "wbk": cameraParam = "wbk"
                    default: cameraParam = control
                    }

                    _ = try await makeDirectRequest(path: "/api/cam/drivelens?\(cameraParam)=\(direction)")
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    try? await fetchDirectCameraState()
                }
            } catch {
                print("Command error: \(error)")
            }

            await MainActor.run { isCommandPending = false }
        }
    }

    func toggleRecord() {
        Task {
            do {
                switch camera.connectionType {
                case .esp32:
                    var request = URLRequest(url: URL(string: "http://\(camera.ip)/api/camera/rec")!)
                    request.httpMethod = "POST"
                    let (data, _) = try await session.data(for: request)

                    // Parse the response to get actual recording state
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let recording = json["recording"] as? Bool {
                        await MainActor.run {
                            self.isRecording = recording
                        }
                    } else {
                        // Fallback: fetch status if response parsing fails
                        try? await fetchESP32Status()
                    }

                case .direct:
                    _ = try await makeDirectRequest(path: "/api/cam/rec?cmd=trig")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    try? await fetchDirectRecordingState()
                }
            } catch {
                print("Record error: \(error)")
            }
        }
    }

    func setWhiteBalance(_ mode: String) {
        Task {
            do {
                switch camera.connectionType {
                case .esp32:
                    var request = URLRequest(url: URL(string: "http://\(camera.ip)/api/camera/wb/\(mode)")!)
                    request.httpMethod = "POST"
                    _ = try await session.data(for: request)
                    // WebSocket push handles the state update automatically

                case .direct:
                    _ = try await makeDirectRequest(path: "/api/cam/setprop?wbm=\(mode)")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    try? await fetchDirectCameraState()
                }
            } catch {
                print("WB error: \(error)")
            }
        }
    }

    func sendFocus(_ action: String) {
        Task {
            do {
                switch camera.connectionType {
                case .esp32:
                    var request = URLRequest(url: URL(string: "http://\(camera.ip)/api/camera/focus/\(action)")!)
                    request.httpMethod = "POST"
                    _ = try await session.data(for: request)

                case .direct:
                    let cmd: String
                    switch action {
                    case "oneshot": cmd = "/api/cam/drivelens?focus=oneshotaf"
                    case "lock": cmd = "/api/cam/drivelens?focus=aflock"
                    case "track": cmd = "/api/cam/drivelens?focus=track"
                    default: cmd = "/api/cam/drivelens?fl=\(action)"
                    }
                    _ = try await makeDirectRequest(path: cmd)
                }
            } catch {
                print("Focus error: \(error)")
            }
        }
    }

    // MARK: - Preset Application

    func applyPreset(_ settings: CameraSettings) async {
        guard isConnected else { return }

        appLog("📷 Applying preset to \(camera.name)")
        appLog("   Saved:   aperture=\(settings.aperture ?? "nil"), iso=\(settings.iso ?? "nil"), shutter=\(settings.shutter ?? "nil")")
        appLog("            ndFilter=\(settings.ndFilter ?? "nil"), wbMode=\(settings.wbMode ?? "nil"), wbKelvin=\(settings.wbKelvin ?? "nil"), aeShift=\(settings.aeShift ?? "nil")")

        // Single state fetch before any adjustments
        switch camera.connectionType {
        case .esp32:
            try? await fetchESP32CameraState()
        case .direct:
            try? await fetchDirectCameraState()
        }
        appLog("   Current: aperture=\(aperture), iso=\(iso), shutter=\(shutter)")

        // Apply iris and ISO sequentially
        if let targetAperture = settings.aperture {
            await adjustToValue(target: targetAperture, control: "iris", inverted: true)
        }
        if let targetISO = settings.iso {
            await adjustToValue(target: targetISO, control: "iso", inverted: false)
        }

        // Remaining settings run sequentially (less common, one setting each)
        if let targetShutter = settings.shutter {
            await adjustToValue(target: targetShutter, control: "shutter", inverted: false)
        }

        if let targetND = settings.ndFilter {
            await adjustToValue(target: targetND, control: "nd", inverted: false)
        }

        if let targetWBMode = settings.wbMode {
            await setWhiteBalanceAsync(targetWBMode)
        }

        if let targetKelvin = settings.wbKelvin {
            // Don't add extra "K" if already present
            let kelvinTarget = targetKelvin.hasSuffix("K") ? targetKelvin : targetKelvin + "K"
            await adjustToValue(target: kelvinTarget, control: "wbk", inverted: false)
        }

        if let targetAEShift = settings.aeShift {
            await adjustToValue(target: targetAEShift, control: "aes", inverted: false)
        }

        appLog("📷 Preset application complete for \(camera.name)")

        // Refresh state after applying
        switch camera.connectionType {
        case .esp32:
            try? await fetchESP32CameraState()
        case .direct:
            try? await fetchDirectCameraState()
        }
    }

    private func adjustToValue(target: String, control: String, inverted: Bool) async {
        // Helper to get current value for this control
        func getCurrentValue() -> String {
            switch control {
            case "iris": return aperture
            case "iso": return iso
            case "shutter": return shutter
            case "nd": return ndFilter
            case "wbk": return wbKelvin
            case "aes": return aeShift
            default: return "--"
            }
        }

        appLog("🎯 Adjusting \(control): target='\(target)', inverted=\(inverted)")

        // Parse target value
        guard let targetNum = parseNumericValue(target) else {
            appLog("⚠️ Cannot parse target for \(control): '\(target)'")
            return
        }

        let currentRaw = getCurrentValue()
        guard let initialNum = parseNumericValue(currentRaw) else {
            appLog("⚠️ Cannot parse current for \(control): '\(currentRaw)'")
            return
        }

        appLog("   current='\(currentRaw)' (\(initialNum))  target='\(target)' (\(targetNum))")

        // Already at target?
        if abs(initialNum - targetNum) < 0.01 {
            appLog("   ✅ Already at target")
            return
        }

        // Determine direction based on initial comparison
        let needsIncrease = targetNum > initialNum
        let direction = (needsIncrease != inverted) ? "plus" : "minus"
        appLog("   Direction: \(direction) (needsIncrease=\(needsIncrease), inverted=\(inverted))")

        // Send adjustment commands (max 30 steps to avoid infinite loop)
        var attempts = 0
        let maxAttempts = 30
        var previousValue: Double = initialNum

        while attempts < maxAttempts {
            attempts += 1

            // Send one adjustment command
            appLog("   Step \(attempts): sending '\(direction)' (current=\(previousValue), target=\(targetNum))")
            await sendCommandAndWait(control, direction)

            // Fetch fresh state after command
            switch camera.connectionType {
            case .esp32:
                // Poll every 50ms until the WS push delivers the new value.
                // Iris (aperture) is mechanical — the motor and Canon API both need more
                // time to settle than ISO/shutter/etc. (electronic). Allow up to 3000ms
                // for iris, 1500ms for everything else. Exits early when value changes.
                let preCommandValue = getCurrentValue()
                let maxPollIterations = (control == "iris") ? 60 : 30
                for _ in 0..<maxPollIterations {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    if getCurrentValue() != preCommandValue { break }
                }
                // Small buffer after the value appears so any in-flight WS message settles
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            case .direct:
                try? await fetchDirectCameraState()
            }

            let currentRaw = getCurrentValue()
            guard let currentNum = parseNumericValue(currentRaw) else {
                appLog("   ⚠️ Cannot parse: '\(currentRaw)'")
                break
            }

            appLog("   → now '\(currentRaw)' (\(currentNum))")

            // Check if we've reached or passed the target
            if needsIncrease {
                if currentNum >= targetNum {
                    appLog("   ✅ Reached target (\(currentNum) >= \(targetNum))")
                    break
                }
            } else {
                if currentNum <= targetNum {
                    appLog("   ✅ Reached target (\(currentNum) <= \(targetNum))")
                    break
                }
            }

            // Check if we're stuck (value didn't change after command)
            if currentNum == previousValue {
                appLog("   ⚠️ Stuck at \(currentNum), stopping")
                break
            }

            previousValue = currentNum
        }

        if attempts >= maxAttempts {
            appLog("   ⚠️ Max attempts (\(maxAttempts)) reached")
        }
    }

    /// Sends a command and waits for it to complete (for preset application)
    private func sendCommandAndWait(_ control: String, _ direction: String) async {
        do {
            switch camera.connectionType {
            case .esp32:
                var request = URLRequest(url: URL(string: "http://\(camera.ip)/api/camera/\(control)/\(direction)")!)
                request.httpMethod = "POST"
                _ = try await session.data(for: request)

            case .direct:
                let cameraParam: String
                switch control {
                case "iris": cameraParam = "iris"
                case "iso": cameraParam = "iso"
                case "shutter": cameraParam = "shutter"
                case "nd": cameraParam = "nd"
                case "aes": cameraParam = "aes"
                case "wbk": cameraParam = "wbk"
                default: cameraParam = control
                }
                _ = try await makeDirectRequest(path: "/api/cam/drivelens?\(cameraParam)=\(direction)")
            }

            // Wait for camera to process the command
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            appLog("   Command error: \(error)")
        }
    }

    /// Sets white balance mode and waits (for preset application)
    private func setWhiteBalanceAsync(_ mode: String) async {
        do {
            switch camera.connectionType {
            case .esp32:
                var request = URLRequest(url: URL(string: "http://\(camera.ip)/api/camera/wb/\(mode)")!)
                request.httpMethod = "POST"
                _ = try await session.data(for: request)
                try await Task.sleep(nanoseconds: 500_000_000)
                try await fetchESP32CameraState()

            case .direct:
                _ = try await makeDirectRequest(path: "/api/cam/setprop?wbm=\(mode)")
                try await Task.sleep(nanoseconds: 500_000_000)
                try await fetchDirectCameraState()
            }
        } catch {
            print("WB error: \(error)")
        }
    }

    private func parseNumericValue(_ value: String) -> Double? {
        // Remove common suffixes/prefixes
        let cleaned = value
            .replacingOccurrences(of: "F", with: "")
            .replacingOccurrences(of: "K", with: "")
            .replacingOccurrences(of: "1/", with: "")
            .replacingOccurrences(of: "--", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Handle fractions like "1/50" -> 50
        if value.contains("/") {
            let parts = value.split(separator: "/")
            if parts.count == 2, let denominator = Double(parts[1]) {
                return denominator
            }
        }

        return Double(cleaned)
    }

    // MARK: - Tally Control

    func updateTallyState(program: Bool, preview: Bool) async {
        guard camera.connectionType == .esp32 else {
            // Direct connection cameras: update border only, no LED control
            await MainActor.run {
                self.tallyProgram = program
                self.tallyPreview = preview
            }
            return
        }

        // Determine command — program always wins over preview
        let command: String
        if program {
            command = "program"
        } else if preview {
            command = "preview"
        } else {
            command = "off"
        }

        // Send to ESP32
        do {
            var request = URLRequest(url: URL(string: "http://\(camera.ip)/api/tally/\(command)")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 2.0
            _ = try await session.data(for: request)

            // Note: Don't update local state here - let WebSocket feedback confirm LED state
            // This creates proper synchronization: POST → ESP32 → WebSocket → Dashboard
        } catch {
            appLog("Tally command error for \(camera.name): \(error)")
        }
    }

    func sendBrightness(_ value: Int) async {
        guard camera.connectionType == .esp32 else { return }
        let clamped = max(0, min(255, value))
        do {
            var request = URLRequest(url: URL(string: "http://\(camera.ip)/api/tally/brightness/\(clamped)")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 2.0
            _ = try await session.data(for: request)
            appLog("Brightness set to \(clamped) on \(camera.name)")
        } catch {
            appLog("Brightness command error for \(camera.name): \(error)")
        }
    }
}
