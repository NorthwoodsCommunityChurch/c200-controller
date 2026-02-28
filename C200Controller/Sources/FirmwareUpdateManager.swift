import Foundation
import Network
import Darwin

@MainActor
class FirmwareUpdateManager: ObservableObject {

    enum BoardStatus: Equatable {
        case idle
        case starting
        case downloading(Int)   // 0-100 %
        case flashing
        case rebooting
        case done(String)       // new version string
        case error(String)

        var displayText: String {
            switch self {
            case .idle:                return "Ready"
            case .starting:            return "Starting..."
            case .downloading(let p):  return "Downloading \(p)%"
            case .flashing:            return "Flashing..."
            case .rebooting:           return "Rebooting..."
            case .done(let v):         return "Done — v\(v)"
            case .error(let msg):      return "Error: \(msg)"
            }
        }

        var isInProgress: Bool {
            switch self {
            case .starting, .downloading, .flashing, .rebooting: return true
            default: return false
            }
        }
    }

    @Published var boardStatuses: [String: BoardStatus] = [:]  // camera.id → status
    @Published var boardVersions: [String: String] = [:]       // camera.id → running version
    @Published var firmwarePath: URL?
    @Published var availableFirmwareVersion: String?
    @Published var isUpdating = false

    private var listener: NWListener?
    private var firmwareData: Data?

    init() {
        firmwarePath = autoDetectFirmwarePath()
        availableFirmwareVersion = autoDetectFirmwareVersion()
    }

    // MARK: - Firmware path detection

    private func autoDetectFirmwarePath() -> URL? {
        // 1. Check app bundle (distributed builds)
        if let bundled = Bundle.main.url(forResource: "c200_bridge", withExtension: "bin") {
            return bundled
        }
        // 2. Fall back to local dev build path
        guard let execURL = Bundle.main.executableURL else { return nil }
        // Resolve symlinks so .build/release → .build/arm64-apple-macosx/release
        var url = execURL.resolvingSymlinksInPath()
        // Walk up: binary → MacOS → Contents → app → release →
        //          arm64-apple-macosx → .build → C200Controller → project root
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
        }
        let candidate = url
            .appendingPathComponent("ESP32Flasher")
            .appendingPathComponent("FirmwareTemplate")
            .appendingPathComponent("build")
            .appendingPathComponent("c200_bridge.bin")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func autoDetectFirmwareVersion() -> String? {
        // 1. Check app bundle (distributed builds)
        if let versionURL = Bundle.main.url(forResource: "firmware_version", withExtension: "txt"),
           let version = try? String(contentsOf: versionURL).trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            return version
        }
        // 2. Fall back to parsing main.c in dev
        guard let execURL = Bundle.main.executableURL else { return nil }
        var url = execURL.resolvingSymlinksInPath()
        for _ in 0..<8 { url = url.deletingLastPathComponent() }
        let mainC = url
            .appendingPathComponent("ESP32Flasher")
            .appendingPathComponent("FirmwareTemplate")
            .appendingPathComponent("main")
            .appendingPathComponent("main.c")
        guard let content = try? String(contentsOf: mainC) else { return nil }
        for line in content.components(separatedBy: "\n") {
            if line.contains("#define FIRMWARE_VERSION") {
                let parts = line.components(separatedBy: "\"")
                if parts.count >= 2 { return parts[1] }
            }
        }
        return nil
    }

    // MARK: - Update orchestration

    func fetchBoardVersions(cameras: [Camera]) async {
        await withTaskGroup(of: Void.self) { group in
            for camera in cameras {
                group.addTask { [weak self] in
                    guard let self else { return }
                    guard let url = URL(string: "http://\(camera.ip)/api/status") else { return }
                    var req = URLRequest(url: url, timeoutInterval: 4)
                    req.timeoutInterval = 4
                    if let (data, _) = try? await URLSession.shared.data(for: req),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let version = json["firmware_version"] as? String {
                        await MainActor.run { self.boardVersions[camera.id] = version }
                    }
                }
            }
        }
    }

    func startUpdate(cameras: [Camera]) async {
        guard let path = firmwarePath else {
            appLog("FirmwareUpdate: No firmware path set")
            return
        }
        guard let data = try? Data(contentsOf: path) else {
            appLog("FirmwareUpdate: Cannot read firmware file at \(path.path)")
            return
        }

        let esp32Cameras = cameras.filter { $0.connectionType == .esp32 }
        guard !esp32Cameras.isEmpty else { return }

        firmwareData = data
        isUpdating = true

        for camera in esp32Cameras {
            boardStatuses[camera.id] = .starting
        }

        let cameraIPs = esp32Cameras.map { $0.ip }
        guard let macIP = getLocalIP(preferringSameSubnetAs: cameraIPs) else {
            appLog("FirmwareUpdate: Cannot determine Mac local IP")
            for camera in esp32Cameras {
                boardStatuses[camera.id] = .error("No local IP found")
            }
            isUpdating = false
            return
        }

        startHTTPServer()
        // Brief pause to ensure port is bound before ESP32s start downloading
        try? await Task.sleep(nanoseconds: 500_000_000)

        let firmwareURL = "http://\(macIP):8765/firmware.bin"
        appLog("FirmwareUpdate: Serving \(data.count) bytes at \(firmwareURL)")

        // Launch all boards simultaneously as detached tasks (avoids @MainActor serialization)
        let group = DispatchGroup()
        for camera in esp32Cameras {
            group.enter()
            let cameraRef = camera
            let urlRef = firmwareURL
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.updateBoard(camera: cameraRef, firmwareURL: urlRef)
                group.leave()
            }
        }

        // Wait for all boards using async-compatible wrapper
        await withCheckedContinuation { continuation in
            group.notify(queue: .main) {
                continuation.resume()
            }
        }

        stopHTTPServer()
        isUpdating = false
    }

    private func updateBoard(camera: Camera, firmwareURL: String) async {
        let cameraID = camera.id
        let cameraIP = camera.ip

        // POST to trigger OTA
        guard let postURL = URL(string: "http://\(cameraIP)/api/ota/update") else { return }
        var request = URLRequest(url: postURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["url": firmwareURL])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                await MainActor.run {
                    self.boardStatuses[cameraID] = .error("HTTP \(http.statusCode)")
                }
                return
            }
        } catch {
            await MainActor.run {
                self.boardStatuses[cameraID] = .error(error.localizedDescription)
            }
            return
        }

        // Poll /api/ota/status until done or error
        guard let statusURL = URL(string: "http://\(cameraIP)/api/ota/status") else { return }
        let deadline = Date().addingTimeInterval(120)

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            do {
                let (data, _) = try await URLSession.shared.data(from: statusURL)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                let state = json["state"] as? String ?? "idle"
                let progress = json["progress"] as? Int ?? 0
                let errMsg = json["error"] as? String ?? ""

                await MainActor.run {
                    switch state {
                    case "downloading": self.boardStatuses[cameraID] = .downloading(progress)
                    case "flashing":    self.boardStatuses[cameraID] = .flashing
                    case "rebooting":   self.boardStatuses[cameraID] = .rebooting
                    case "error":       self.boardStatuses[cameraID] = .error(errMsg.isEmpty ? "Unknown error" : errMsg)
                    default: break
                    }
                }

                if state == "error" { return }

                if state == "rebooting" {
                    // Board is restarting — wait 15s then verify new version
                    appLog("FirmwareUpdate: \(camera.name) rebooting, waiting 15s...")
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    let newVersion = await confirmVersion(cameraIP: cameraIP)
                    await MainActor.run {
                        self.boardStatuses[cameraID] = .done(newVersion ?? "?")
                    }
                    return
                }
            } catch {
                // Connection refused during reboot is expected — just keep waiting
                appLog("FirmwareUpdate: Poll error for \(cameraIP): \(error.localizedDescription)")
            }
        }

        // Timed out
        await MainActor.run {
            if case .rebooting = self.boardStatuses[cameraID] ?? .idle { } else {
                self.boardStatuses[cameraID] = .error("Timeout")
            }
        }
    }

    private func confirmVersion(cameraIP: String) async -> String? {
        guard let url = URL(string: "http://\(cameraIP)/api/status") else { return nil }
        for _ in 0..<5 {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["firmware_version"] as? String {
                return version
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return nil
    }

    // MARK: - Minimal HTTP server (serves firmware binary)

    private func startHTTPServer() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: 8765)
            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleFirmwareRequest(connection)
                }
            }
            listener?.start(queue: .main)
            appLog("FirmwareUpdate: HTTP server started on port 8765")
        } catch {
            appLog("FirmwareUpdate: Failed to start HTTP server: \(error)")
        }
    }

    private func stopHTTPServer() {
        listener?.cancel()
        listener = nil
        appLog("FirmwareUpdate: HTTP server stopped")
    }

    private func handleFirmwareRequest(_ connection: NWConnection) {
        connection.start(queue: .main)
        // Capture firmwareData on MainActor before entering the Sendable closure
        let data = firmwareData
        // Read the GET request (we ignore headers, just serve the file)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in
            guard let data else {
                connection.cancel()
                return
            }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
            var response = header.data(using: .utf8)!
            response.append(data)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // MARK: - Network utilities

    /// Find the Mac's local IP on any `en*` interface, preferring one in the same
    /// /24 subnet as the cameras so the ESP32s can actually reach the firmware server.
    private func getLocalIP(preferringSameSubnetAs cameraIPs: [String]) -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }

        var candidates: [String] = []
        var ptr = addrs
        while let addr = ptr {
            let name = String(cString: addr.pointee.ifa_name)
            if name.hasPrefix("en"),
               addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr.pointee.ifa_addr,
                            socklen_t(addr.pointee.ifa_addr.pointee.sa_len),
                            &host, socklen_t(host.count),
                            nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                if ip != "127.0.0.1" && !ip.isEmpty {
                    candidates.append(ip)
                }
            }
            ptr = addr.pointee.ifa_next
        }

        // Prefer an IP in the same /24 as any camera
        for cameraIP in cameraIPs {
            let camPrefix = cameraIP.components(separatedBy: ".").prefix(3).joined(separator: ".")
            if let match = candidates.first(where: { $0.hasPrefix(camPrefix + ".") }) {
                appLog("FirmwareUpdate: Using local IP \(match) (same subnet as camera)")
                return match
            }
        }

        // Fall back to first candidate
        if let first = candidates.first {
            appLog("FirmwareUpdate: Using local IP \(first) (fallback)")
            return first
        }
        return nil
    }
}
