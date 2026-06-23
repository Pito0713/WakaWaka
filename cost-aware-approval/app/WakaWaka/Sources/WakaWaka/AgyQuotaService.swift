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
            let ports = self.discoverAllPorts()
            self.tryPorts(ports, index: 0, completion: completion)
        }
    }

    // MARK: - Port discovery

    private func discoverAllPorts() -> [Int] {
        findAgyPIDs().flatMap { listenPorts(for: $0) }
    }

    private func findAgyPIDs() -> [Int] {
        run("ps -ax -o pid=,comm= 2>/dev/null")
            .components(separatedBy: "\n")
            .compactMap { line -> Int? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Split on first space only — handles paths with spaces
                guard !trimmed.isEmpty,
                      let spaceIdx = trimmed.firstIndex(of: " ") else { return nil }
                let pidStr = String(trimmed[trimmed.startIndex..<spaceIdx])
                let comm   = trimmed[trimmed.index(after: spaceIdx)...].trimmingCharacters(in: .whitespaces)
                guard let pid = Int(pidStr) else { return nil }
                return (comm as NSString).lastPathComponent == "agy" ? pid : nil
            }
    }

    private func listenPorts(for pid: Int) -> [Int] {
        run("lsof -nP -iTCP -sTCP:LISTEN -a -p \(pid) 2>/dev/null")
            .components(separatedBy: "\n")
            .compactMap { line -> Int? in
                guard line.contains("(LISTEN)") else { return nil }
                // Support both IPv4 loopback (127.0.0.1) and IPv6 loopback ([::1])
                for prefix in ["127.0.0.1:", "[::1]:"] {
                    guard let prefixRange = line.range(of: prefix),
                          let spaceRange  = line[prefixRange.upperBound...].range(of: " ")
                    else { continue }
                    return Int(String(line[prefixRange.upperBound..<spaceRange.lowerBound]))
                }
                return nil
            }
    }

    // MARK: - API probing (try each discovered port until one responds)

    private func tryPorts(_ ports: [Int], index: Int, completion: @escaping (AgyQuota?) -> Void) {
        guard index < ports.count else { completion(nil); return }
        callAPI(port: ports[index]) { [weak self] quota in
            if let quota {
                completion(quota)
            } else {
                self?.tryPorts(ports, index: index + 1, completion: completion)
            }
        }
    }

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

    // MARK: - Parsing

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
            let resetDate = parseDate(resetStr)
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

    // Handles both plain ISO-8601 and sub-second variants (e.g. 2026-01-01T00:00:00.123Z)
    private static func parseDate(_ s: String) -> Date? {
        let withMS = ISO8601DateFormatter()
        withMS.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withMS.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
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
        // Read stdout BEFORE waitUntilExit — prevents pipe-buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
