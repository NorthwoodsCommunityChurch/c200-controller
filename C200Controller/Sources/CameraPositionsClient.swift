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
        guard let url = URL(string: "http://\(host):\(port)/api/assignments") else { return }
        guard let (data, _) = try? await session.data(from: url) else { return }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        var result: [Int: CameraAssignment] = [:]
        for item in array {
            guard let num = item["number"] as? Int else { continue }
            let op = item["operator"] as? String  // nullable — nil when no operator
            let lenses = item["lenses"] as? [String] ?? []
            result[num] = CameraAssignment(cameraNumber: num, operatorName: op, lenses: lenses)
        }

        let captured = result
        DispatchQueue.main.async { [weak self] in
            self?.onAssignmentsUpdate?(captured)
        }
    }
}
