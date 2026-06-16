import Foundation

// MARK: - pending.json
struct PendingData: Decodable {
    let session_id: String?
    let tool_name: String?
    let transcript_path: String?
    let timestamp: String?
    /// Raw tool_input stored as formatted string for display
    let toolInputSummary: String

    enum CodingKeys: String, CodingKey {
        case session_id, tool_name, transcript_path, timestamp, tool_input
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session_id = try c.decodeIfPresent(String.self, forKey: .session_id)
        tool_name  = try c.decodeIfPresent(String.self, forKey: .tool_name)
        transcript_path = try c.decodeIfPresent(String.self, forKey: .transcript_path)
        timestamp  = try c.decodeIfPresent(String.self, forKey: .timestamp)

        // Decode tool_input as [String: String] for display; fall back gracefully
        if let dict = try? c.decode([String: String].self, forKey: .tool_input) {
            toolInputSummary = dict.map { "\($0.key): \(String($0.value.prefix(80)))" }
                                   .joined(separator: "\n")
        } else {
            toolInputSummary = "(complex input)"
        }
    }
}

// MARK: - Parser output
struct TurnDelta: Codable {
    let input: Int
    let output: Int
}

struct UsageOutput: Codable {
    let cumulativeInput: Int
    let cumulativeOutput: Int
    let cumulativeCacheRead: Int
    let cumulativeCacheCreation: Int
    let lastTurnDelta: TurnDelta?
    let estimatedCostUSD: Double
}
