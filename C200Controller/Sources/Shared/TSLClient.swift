import Foundation
import Network

class TSLClient {
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private let port: UInt16
    private var dataBuffer = Data()

    var onConnectionChange: ((Bool) -> Void)?   // listener ready/stopped
    var onClientConnected: (() -> Void)?         // switcher connected
    var onClientDisconnected: (() -> Void)?      // switcher disconnected
    var onTallyUpdate: ((Int, Bool, Bool) -> Void)?

    /// Fires on every successfully-parsed packet, regardless of whether the
    /// tally state actually changed. Used by CameraManager to maintain a
    /// `discoveredTSLIDs` map so the GUI can show operators what UMD IDs the
    /// switcher is actively sending (and let them pick one per box from a
    /// real list instead of guessing numbers). Carries the display text the
    /// switcher attached to the packet, when available — Carbonite/Ultrix
    /// typically put the source's UMD label there ("CAM1", "WIDE", etc.).
    /// Parameters: `(umdID, displayName, isProgram, isPreview)`
    var onPacketObserved: ((Int, String, Bool, Bool) -> Void)?

    // Per-index state cache so we only dispatch onTallyUpdate when the resolved tally
    // state actually changes. Switchers re-send the same state every cycle (often many
    // times per second per index) and a busy switcher emits thousands of indices we don't
    // even care about. Dispatching every one to @MainActor was overwhelming the main
    // actor and crashing the app under sustained cut storms (KERN_INVALID_ADDRESS in
    // KeyPath._projectReadOnly while reading @Published cameras). Accessed only from
    // the NWConnection receive callback — single-threaded, no lock needed.
    private var lastTallyState: [Int: (program: Bool, preview: Bool)] = [:]

    init(host: String, port: UInt16) {
        // host is ignored - we listen on the specified port for incoming TSL data
        self.port = port
    }

    func connect() {
        appLog("TSL: Starting TCP listener on port \(port)")

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

            listener?.stateUpdateHandler = { [weak self] state in
                appLog("TSL: Listener state: \(state)")
                switch state {
                case .ready:
                    appLog("TSL: Listener ready on port \(self?.port ?? 0)")
                    self?.onConnectionChange?(true)
                case .failed(let error):
                    appLog("TSL: Listener failed: \(error)")
                    self?.onConnectionChange?(false)
                case .cancelled:
                    appLog("TSL: Listener cancelled")
                    self?.onConnectionChange?(false)
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                appLog("TSL: New connection from: \(connection.endpoint)")
                self?.handleConnection(connection)
            }

            listener?.start(queue: .main)

        } catch {
            appLog("TSL: Failed to create listener: \(error)")
            onConnectionChange?(false)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
        onClientConnected?()

        connection.stateUpdateHandler = { [weak self] state in
            appLog("TSL: Connection state: \(state)")
            if case .cancelled = state {
                self?.activeConnections.removeAll { $0 === connection }
                if self?.activeConnections.isEmpty == true {
                    self?.onClientDisconnected?()
                }
            }
            if case .failed = state {
                self?.activeConnections.removeAll { $0 === connection }
                if self?.activeConnections.isEmpty == true {
                    self?.onClientDisconnected?()
                }
            }
        }

        connection.start(queue: .main)
        receiveData(from: connection)
    }

    private func receiveData(from connection: NWConnection) {
        // For TCP, receive data in chunks and parse TSL messages
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            if let error = error {
                appLog("TSL: Receive error: \(error)")
                return
            }

            if let data = data, !data.isEmpty {
                self?.parseTSLData(data)
            }

            // Continue receiving if connection is still active
            if !isComplete {
                self?.receiveData(from: connection)
            } else {
                appLog("TSL: Connection completed/closed")
            }
        }
    }

    func disconnect() {
        activeConnections.forEach { $0.cancel() }
        activeConnections.removeAll()
        listener?.cancel()
        listener = nil
        dataBuffer.removeAll()
        onConnectionChange?(false)
    }

    private func parseTSLData(_ data: Data) {
        // Append to buffer for TCP stream handling
        dataBuffer.append(data)

        // Process all complete messages in buffer
        while dataBuffer.count >= 4 {
            // Safe access to bytes
            let bytes = [UInt8](dataBuffer.prefix(4))
            let pbc = Int(bytes[0]) | (Int(bytes[1]) << 8)
            let version = bytes[2]

            // TSL 5.0 detection: valid length and version byte is 0
            // Note: PBC is payload byte count (doesn't include the 2-byte PBC field itself)
            let totalMessageLength = pbc + 2

            if pbc >= 10 && pbc <= 1000 && totalMessageLength <= dataBuffer.count && version == 0x00 {
                // TSL 5.0 message
                let messageData = Data(dataBuffer.prefix(totalMessageLength))
                dataBuffer.removeFirst(totalMessageLength)
                parseTSL5(messageData)
                continue
            }

            // TSL 3.1: fixed 18-byte messages (pbc > 1000 since the first two bytes are
            // address + control, forming a large little-endian value)
            if pbc > 1000 {
                if dataBuffer.count >= 18 {
                    let messageData = Data(dataBuffer.prefix(18))
                    dataBuffer.removeFirst(18)
                    parseTSL31(messageData)
                    continue
                }
                // Incomplete TSL 3.1 — wait for the rest of the 18-byte packet
                break
            }

            // Incomplete TSL 5.0 — wait for more data
            if pbc >= 10 && pbc <= 1000 && totalMessageLength > dataBuffer.count {
                break
            }

            // Unrecognizable byte — advance by 1 to resync rather than dropping all buffered data
            appLog("TSL: Unrecognized byte 0x\(String(format: "%02X", bytes[0])) at buffer head, skipping")
            dataBuffer.removeFirst(1)
        }
    }

    private func parseTSL31(_ data: Data) {
        // TSL UMD 3.1 format:
        // Byte 0: Address (0-126)
        // Byte 1: Control byte (bits: 0-1=tally1, 2-3=tally2, 4-5=tally3, 6-7=tally4)
        // Bytes 2-17: 16 character display text (ASCII, space-padded)

        guard data.count >= 18 else {
            appLog("TSL 3.1: Data too short (\(data.count) bytes)")
            return
        }

        let address = Int(data[0])
        let control = data[1]

        // Tally 1 = Program/Red (bits 0-1), Tally 2 = Preview/Green (bits 2-3)
        let tally1 = control & 0x03
        let tally2 = (control >> 2) & 0x03

        let isProgram = tally1 > 0
        let isPreview = tally2 > 0

        // TSL index is typically 1-based, convert to our index
        let index = address + 1

        // Display name: 16 ASCII bytes starting at offset 2, trimmed of trailing spaces / nulls.
        let nameBytes = data.subdata(in: 2..<18)
        let name = String(data: nameBytes, encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0")) ?? ""

        // Fire the per-packet observer so the discovery cache sees every packet,
        // even when state is unchanged (so packet counts keep ticking up).
        DispatchQueue.main.async { [weak self] in
            self?.onPacketObserved?(index, name, isProgram, isPreview)
        }

        let prev = lastTallyState[index]
        if prev?.program == isProgram && prev?.preview == isPreview {
            return  // unchanged — switcher re-sending; skip the main-actor hop
        }
        lastTallyState[index] = (isProgram, isPreview)

        DispatchQueue.main.async { [weak self] in
            self?.onTallyUpdate?(index, isProgram, isPreview)
        }
    }

    private func parseTSL5(_ data: Data) {
        // TSL UMD 5.0 format:
        // Bytes 0-1: PBC (Packet Byte Count) - little endian
        // Byte 2: Version (0x00)
        // Byte 3: Flags
        // Bytes 4-5: Screen index (little endian)
        // Bytes 6-7: Index (display/source index) - little endian
        // Bytes 8-9: Control (tally data) - little endian
        // Bytes 10-11: Length of text (little endian)
        // Remaining: Text (UTF-16LE typically)

        guard data.count >= 12 else {
            appLog("TSL 5.0: Data too short (\(data.count) bytes)")
            return
        }

        let index = Int(data[6]) | (Int(data[7]) << 8)
        let control = Int(data[8]) | (Int(data[9]) << 8)

        // TSL 5.0 tally uses 2 bits per tally (brightness levels 0-3):
        // Bits 0-1: Tally 1 (Program/Red)
        // Bits 2-3: Tally 2 (Preview/Green)
        // Bits 4-5: Tally 3
        // Bits 6-7: Tally 4
        let tally1 = control & 0x03
        let tally2 = (control >> 2) & 0x03
        let isProgram = tally1 > 0
        let isPreview = tally2 > 0

        // Display text: UTF-16LE characters at bytes 12..(12+len). LEN is a
        // count of UTF-16 code units, so byte count = LEN * 2. Some switchers
        // send ASCII via TSL 5.0 — fall back to ASCII if UTF-16LE decode fails.
        var name = ""
        if data.count >= 12 {
            let textLenCodeUnits = Int(data[10]) | (Int(data[11]) << 8)
            let textByteCount = textLenCodeUnits * 2
            let textEnd = min(12 + textByteCount, data.count)
            if textEnd > 12 {
                let textBytes = data.subdata(in: 12..<textEnd)
                if let s = String(data: textBytes, encoding: .utf16LittleEndian) {
                    name = s.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let s = String(data: textBytes, encoding: .ascii) {
                    name = s.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.onPacketObserved?(index, name, isProgram, isPreview)
        }

        let prev = lastTallyState[index]
        if prev?.program == isProgram && prev?.preview == isPreview {
            return  // unchanged — skip the main-actor hop
        }
        lastTallyState[index] = (isProgram, isPreview)

        // Index is already 1-based in TSL 5.0
        DispatchQueue.main.async { [weak self] in
            self?.onTallyUpdate?(index, isProgram, isPreview)
        }
    }
}
