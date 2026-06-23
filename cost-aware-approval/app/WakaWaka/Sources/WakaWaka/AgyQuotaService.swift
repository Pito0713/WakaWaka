import Foundation

struct AgyQuota {
    let remainingFraction: Double  // 0–1, remaining (1 = full)
    let resetTime: Date
    let tier: String               // "MEDIUM", "HIGH", "LOW", etc.
    let fetchedAt: Date

    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 300 }

    func countdownText(from now: Date = Date()) -> String {
        let rem = resetTime.timeIntervalSince(now)
        guard rem > 0 else { return "↻ —" }
        let h = Int(rem) / 3600
        let m = (Int(rem) % 3600) / 60
        return h > 0 ? "↻ \(h)h \(m)m" : "↻ \(m)m"
    }
}

final class AgyQuotaService {
    static let shared = AgyQuotaService()
    private init() {}

    func fetch(completion: @escaping (AgyQuota?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { completion(nil); return }
            guard let port = self.discoverPort() else { completion(nil); return }
            self.callAPI(port: port, completion: completion)
        }
    }

    // MARK: - Port discovery

    private func discoverPort() -> Int? {
        for pid in findAgyPIDs() {
            let ports = listenPorts(for: pid)
            if ports.count >= 2 { return ports[1] }
            if let p = ports.first { return p }
        }
        return nil
    }

    private func findAgyPIDs() -> [Int] {
        run("ps -ax -o pid=,comm= 2>/dev/null")
            .components(separatedBy: "\n")
            .compactMap { line -> Int? in
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                guard parts.count >= 2 else { return nil }
                guard parts[1].hasSuffix("/agy") || parts[1] == "agy" else { return nil }
                return Int(parts[0])
            }
    }

    private func listenPorts(for pid: Int) -> [Int] {
        run("lsof -nP -iTCP -sTCP:LISTEN -a -p \(pid) 2>/dev/null")
            .components(separatedBy: "\n")
            .compactMap { line -> Int? in
                guard line.contains("127.0.0.1:"), line.contains("(LISTEN)") else { return nil }
                guard let colonRange = line.range(of: "127.0.0.1:"),
                      let spaceRange = line[colonRange.upperBound...].range(of: " ")
                else { return nil }
                return Int(String(line[colonRange.upperBound..<spaceRange.lowerBound]))
            }
    }

    // MARK: - API call

    private func callAPI(port: Int, completion: @escaping (AgyQuota?) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus")
        else { completion(nil); return }

        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        URLSession.shared.dataTask(with: req) { data, _, _ in
            completion(data.flatMap(Self.parse))
        }.resume()
    }

    private static func parse(_ data: Data) -> AgyQuota? {
        guard
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let status  = json["userStatus"]               as? [String: Any],
            let cascade = status["cascadeModelConfigData"] as? [String: Any],
            let configs = cascade["clientModelConfigs"]    as? [[String: Any]]
        else { return nil }

        // Prefer the recommended model; fall back to first model with quotaInfo
        let cfg = configs.first(where: {
            ($0["isRecommended"] as? Bool) == true && $0["quotaInfo"] != nil
        }) ?? configs.first(where: { $0["quotaInfo"] != nil })

        guard
            let cfg       = cfg,
            let qi        = cfg["quotaInfo"]        as? [String: Any],
            let remaining = qi["remainingFraction"] as? Double,
            let resetStr  = qi["resetTime"]         as? String,
            let resetDate = ISO8601DateFormatter().date(from: resetStr)
        else { return nil }

        let tier: String
        if let label = cfg["label"] as? String,
           let open  = label.lastIndex(of: "("),
           let close = label.lastIndex(of: ")"),
           open < close {
            tier = String(label[label.index(after: open)..<close]).uppercased()
        } else {
            tier = "—"
        }

        return AgyQuota(
            remainingFraction: remaining,
            resetTime:         resetDate,
            tier:              tier,
            fetchedAt:         Date()
        )
    }

    // MARK: - Shell helper

    private func run(_ cmd: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", cmd]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
