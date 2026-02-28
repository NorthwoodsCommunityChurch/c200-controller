import Foundation

struct CameraAssignment {
    let cameraNumber: Int
    let operatorName: String?   // null when no operator is assigned
    let lenses: [String]
}

class CameraPositionsClient: @unchecked Sendable {
    var onAssignmentsUpdate: (([Int: CameraAssignment]) -> Void)?

    private var pollTask: Task<Void, Never>?
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    func start(host: String, port: Int) {
        stop()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(host: host, port: port)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll(host: String, port: Int) async {
        // Accept a full URL in host (e.g. "http://localhost:8080") or a bare hostname.
        let urlString: String
        if host.hasPrefix("http://") || host.hasPrefix("https://") {
            let base = host.hasSuffix("/") ? String(host.dropLast()) : host
            urlString = "\(base)/api/config"
        } else {
            urlString = "http://\(host):\(port)/api/config"
        }
        guard let url = URL(string: urlString) else { return }
        guard let (data, _) = try? await session.data(from: url) else { return }

        // /api/config returns {"serviceName":..., "cameras":[{"number":N, "operatorName":"...", "lenses":[{"name":"..."}]}]}
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = root["cameras"] as? [[String: Any]] else { return }

        var result: [Int: CameraAssignment] = [:]
        for item in array {
            guard let num = item["number"] as? Int else { continue }
            let op = item["operatorName"] as? String  // nil when no operator assigned
            // Lenses are objects {"name": "70 - 200", "photoFilename": "..."}
            let lensObjects = item["lenses"] as? [[String: Any]] ?? []
            let lenses = lensObjects.compactMap { $0["name"] as? String }
            result[num] = CameraAssignment(cameraNumber: num, operatorName: op, lenses: lenses)
        }

        let captured = result
        DispatchQueue.main.async { [weak self] in
            self?.onAssignmentsUpdate?(captured)
        }
    }
}
