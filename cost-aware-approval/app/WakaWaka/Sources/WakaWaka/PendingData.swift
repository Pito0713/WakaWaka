import Foundation

// MARK: - Flexible JSON value (supports mixed-type tool_input dicts)

indirect enum JSONValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode(Int.self)    { self = .int(v);    return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
        if c.decodeNil()                       { self = .null;      return }
        if let v = try? c.decode([JSONValue].self)         { self = .array(v);  return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type")
        )
    }

    var str: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    /// Best-effort display string for any JSON value
    var displayString: String {
        switch self {
        case .string(let s):  return s
        case .int(let i):     return "\(i)"
        case .double(let d):  return "\(d)"
        case .bool(let b):    return b ? "true" : "false"
        case .null:           return "null"
        case .array(let a):   return a.map { $0.displayString }.joined(separator: ", ")
        case .object:         return "(object)"
        }
    }
}

// MARK: - Diff sections (colored blocks in detail view)

struct DiffSection: Identifiable, Equatable {
    enum Kind: Equatable { case header, removed, added, plain }
    let id   = UUID()
    let kind: Kind
    let text: String

    static func == (lhs: DiffSection, rhs: DiffSection) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
    }
}

// MARK: - pending_<session_id>.json

enum RiskLevel: String, Decodable {
    case critical, high, medium, low
}

enum ApprovalEnforcement: String, Decodable {
    case review, deny
}

struct PendingData: Decodable {
    let session_id: String?
    /// Codex only. Its `session_id` is the approval's own UUID, so this is the
    /// field that identifies the session — the key the active-agents panel
    /// needs to match an approval back to the agent waiting on it.
    let codex_session_id: String?
    let tool_name: String?
    let risk_level: RiskLevel?   // nil → medium (non-Bash tools)
    /// Missing in older pending files; nil preserves the legacy review flow.
    let enforcement: ApprovalEnforcement?
    let transcript_path: String?
    let timestamp: String?

    /// 單行標題：顯示在 tool 名稱旁（路徑或指令前幾字）
    let toolInputSummary: String
    /// 帶顏色色塊的結構化區塊（removed=紅, added=綠）；文字截斷至合理長度
    let toolInputSections: [DiffSection]
    /// 同上，但不截斷文字——用於「展開全文」模式
    let toolInputSectionsFull: [DiffSection]

    /// Set to true when the hook process exited before the user made a decision
    /// (timeout or Claude Code killed the hook). WakaWaka shows "已逾時" state.
    let hookExited: Bool?
    /// ISO-8601 timestamp when the hook wrote the tombstone.
    let hookExitedAt: String?
    /// Set to true at the 8-minute warn threshold. Hook is still alive and waiting.
    /// WakaWaka should auto-open its popover and show a red "auto-deny soon" banner.
    let hookUrgent: Bool?

    /// True when this item is a tombstone (hook already gone; tool was NOT executed).
    var isExpired: Bool { hookExited == true }

    /// Originating agent: "agy", "codex", "claude-code", or nil (treated as Claude Code).
    let agent: String?

    var isPolicyDenied: Bool { enforcement == .deny }
    var canBeAllowed: Bool { !isExpired && !isPolicyDenied }

    var agentDisplayLabel: String {
        switch agent {
        case "agy": return "agy"
        case "codex": return "Codex"
        case "claude-code", .none: return "Claude"
        default: return agent ?? "?"
        }
    }

    enum CodingKeys: String, CodingKey {
        case session_id, tool_name, risk_level, enforcement, transcript_path, timestamp, tool_input
        case hookExited, hookExitedAt
        case hookUrgent
        case agent
        case codex_session_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session_id      = try c.decodeIfPresent(String.self,    forKey: .session_id)
        tool_name       = try c.decodeIfPresent(String.self,    forKey: .tool_name)
        risk_level      = try c.decodeIfPresent(RiskLevel.self, forKey: .risk_level)
        enforcement     = try c.decodeIfPresent(ApprovalEnforcement.self, forKey: .enforcement)
        transcript_path = try c.decodeIfPresent(String.self,    forKey: .transcript_path)
        timestamp       = try c.decodeIfPresent(String.self,    forKey: .timestamp)
        hookExited      = try c.decodeIfPresent(Bool.self,       forKey: .hookExited)
        hookExitedAt    = try c.decodeIfPresent(String.self,    forKey: .hookExitedAt)
        hookUrgent      = try c.decodeIfPresent(Bool.self,       forKey: .hookUrgent)
        agent           = try c.decodeIfPresent(String.self,    forKey: .agent)
        codex_session_id = try c.decodeIfPresent(String.self,   forKey: .codex_session_id)

        let raw = try? c.decode([String: JSONValue].self, forKey: .tool_input)
        toolInputSummary      = Self.buildSummary(toolName: tool_name, raw: raw)
        toolInputSections     = Self.buildSections(toolName: tool_name, raw: raw, full: false)
        toolInputSectionsFull = Self.buildSections(toolName: tool_name, raw: raw, full: true)
    }

}
