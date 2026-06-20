import Foundation

// MARK: - Flexible JSON value (supports mixed-type tool_input dicts)

private indirect enum JSONValue: Decodable {
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

struct DiffSection: Identifiable {
    enum Kind: Equatable { case header, removed, added, plain }
    let id   = UUID()
    let kind: Kind
    let text: String
}

// MARK: - pending_<session_id>.json

enum RiskLevel: String, Decodable {
    case critical, high, medium, low
}

struct PendingData: Decodable {
    let session_id: String?
    let tool_name: String?
    let risk_level: RiskLevel?   // nil → medium (non-Bash tools)
    let transcript_path: String?
    let timestamp: String?

    /// 單行標題：顯示在 tool 名稱旁（路徑或指令前幾字）
    let toolInputSummary: String
    /// 完整內容：帶顏色色塊的結構化區塊（removed=紅, added=綠）
    let toolInputSections: [DiffSection]

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

    enum CodingKeys: String, CodingKey {
        case session_id, tool_name, risk_level, transcript_path, timestamp, tool_input
        case hookExited, hookExitedAt
        case hookUrgent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session_id      = try c.decodeIfPresent(String.self,    forKey: .session_id)
        tool_name       = try c.decodeIfPresent(String.self,    forKey: .tool_name)
        risk_level      = try c.decodeIfPresent(RiskLevel.self, forKey: .risk_level)
        transcript_path = try c.decodeIfPresent(String.self,    forKey: .transcript_path)
        timestamp       = try c.decodeIfPresent(String.self,    forKey: .timestamp)
        hookExited      = try c.decodeIfPresent(Bool.self,       forKey: .hookExited)
        hookExitedAt    = try c.decodeIfPresent(String.self,    forKey: .hookExitedAt)
        hookUrgent      = try c.decodeIfPresent(Bool.self,       forKey: .hookUrgent)

        let raw = try? c.decode([String: JSONValue].self, forKey: .tool_input)
        toolInputSummary  = Self.buildSummary(toolName: tool_name, raw: raw)
        toolInputSections = Self.buildSections(toolName: tool_name, raw: raw)
    }

    // MARK: - Summary（單行標題）

    /// 單行，顯示在 popover 標題區：路徑縮短版或指令前段
    private static func buildSummary(toolName: String?, raw: [String: JSONValue]?) -> String {
        guard let raw else { return "(no input)" }
        switch toolName {
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            return raw["file_path"]?.str.map { shortenPath($0) } ?? "(no path)"
        case "Bash":
            let cmd = raw["command"]?.str ?? "(no command)"
            // 只取第一行，最多 80 字
            let firstLine = cmd.split(separator: "\n").first.map(String.init) ?? cmd
            return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
        case "WebFetch":
            return raw["url"]?.str ?? "(no url)"
        case "WebSearch":
            return raw["query"]?.str ?? "(no query)"
        default:
            // 取第一個有值的 string 欄位
            let first = raw.sorted { $0.key < $1.key }.compactMap { k, v -> String? in
                guard let s = v.str, !s.isEmpty else { return nil }
                return "\(k): \(s.prefix(60))"
            }.first
            return first ?? "(no input)"
        }
    }

    // MARK: - Sections（帶顏色的結構化內容區塊）

    private static func buildSections(toolName: String?, raw: [String: JSONValue]?) -> [DiffSection] {
        guard let raw, !raw.isEmpty else { return [] }

        switch toolName {

        case "Edit":
            let file    = raw["file_path"]?.str ?? "?"
            let old     = raw["old_string"]?.str ?? ""
            let new     = raw["new_string"]?.str ?? ""
            let replace = raw["replace_all"]?.displayString
            var sections: [DiffSection] = [.init(kind: .header, text: "📄 \(file)")]
            if let r = replace, r == "true" {
                sections.append(.init(kind: .header, text: "replace_all: true"))
            }
            sections += lineDiff(old: old, new: new)
            return sections

        case "MultiEdit":
            let file = raw["file_path"]?.str ?? "?"
            var sections: [DiffSection] = [.init(kind: .header, text: "📄 \(file)")]
            if case .array(let edits) = raw["edits"] {
                for (i, edit) in edits.enumerated() {
                    if case .object(let e) = edit {
                        sections.append(.init(kind: .header, text: "── 修改 \(i + 1) ──"))
                        sections += lineDiff(old: e["old_string"]?.str ?? "",
                                             new: e["new_string"]?.str ?? "")
                    }
                }
            }
            return sections

        case "Write":
            let file    = raw["file_path"]?.str ?? "?"
            let content = raw["content"]?.str ?? ""
            return [
                .init(kind: .header, text: "📄 \(file)"),
                .init(kind: .plain,  text: content.isEmpty ? "(empty file)" : cap(content, 1000)),
            ]

        case "Bash":
            return [.init(kind: .plain, text: raw["command"]?.str ?? "(no command)")]

        case "WebFetch":
            let url    = raw["url"]?.str ?? "?"
            let method = raw["method"]?.str ?? "GET"
            var sections: [DiffSection] = [.init(kind: .header, text: "\(method)  \(url)")]
            if let body = raw["body"]?.str, !body.isEmpty {
                sections.append(.init(kind: .plain, text: cap(body, 500)))
            }
            return sections

        case "WebSearch":
            let query = raw["query"]?.str ?? "?"
            var sections: [DiffSection] = [.init(kind: .plain, text: "query: \(query)")]
            if let l = raw["max_results"]?.displayString {
                sections.append(.init(kind: .plain, text: "max_results: \(l)"))
            }
            return sections

        case "Read":
            var sections: [DiffSection] = [.init(kind: .header, text: "📄 \(raw["file_path"]?.str ?? "?")")]
            if let offset = raw["offset"]?.displayString { sections.append(.init(kind: .plain, text: "offset: \(offset)")) }
            if let limit  = raw["limit"]?.displayString  { sections.append(.init(kind: .plain, text: "limit: \(limit)")) }
            return sections

        case "NotebookEdit":
            let file = raw["notebook_path"]?.str ?? "?"
            var sections: [DiffSection] = [.init(kind: .header, text: "📄 \(file)")]
            let op = raw["new_source"]?.str.map { cap($0, 400) } ?? raw["cell_type"]?.str
            if let op { sections.append(.init(kind: .plain, text: op)) }
            return sections

        default:
            return raw.sorted { $0.key < $1.key }.map { k, v in
                let val = v.str.map { cap($0, 300) } ?? "[\(v.displayString)]"
                return DiffSection(kind: .plain, text: "[\(k)]\n\(val)")
            }
        }
    }

    // MARK: - Helpers

    /// LCS-based line diff: interleaves removed (red) and added (green) lines.
    /// Falls back to two-block display when either side exceeds 150 lines.
    private static func lineDiff(old: String, new: String) -> [DiffSection] {
        guard !old.isEmpty || !new.isEmpty else { return [] }
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let m = oldLines.count, n = newLines.count

        guard m <= 150, n <= 150 else {
            var out: [DiffSection] = []
            if !old.isEmpty { out.append(.init(kind: .removed, text: cap(old, 800))) }
            if !new.isEmpty { out.append(.init(kind: .added,   text: cap(new, 800))) }
            return out
        }

        // DP table for LCS
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                dp[i][j] = oldLines[i-1] == newLines[j-1]
                    ? dp[i-1][j-1] + 1
                    : max(dp[i-1][j], dp[i][j-1])
            }
        }

        // Backtrack → (kind, line) pairs
        var raw: [(DiffSection.Kind, String)] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, oldLines[i-1] == newLines[j-1] {
                raw.append((.plain,   oldLines[i-1])); i -= 1; j -= 1
            } else if j > 0, (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                raw.append((.added,   newLines[j-1])); j -= 1
            } else {
                raw.append((.removed, oldLines[i-1])); i -= 1
            }
        }
        raw.reverse()

        // Group consecutive same-kind lines into DiffSections
        var sections: [DiffSection] = []
        var curKind: DiffSection.Kind? = nil
        var curLines: [String] = []
        for (kind, line) in raw {
            if kind == curKind {
                curLines.append(line)
            } else {
                if let k = curKind, !curLines.isEmpty {
                    sections.append(.init(kind: k, text: curLines.joined(separator: "\n")))
                }
                curKind  = kind
                curLines = [line]
            }
        }
        if let k = curKind, !curLines.isEmpty {
            sections.append(.init(kind: k, text: curLines.joined(separator: "\n")))
        }
        return sections
    }

    /// Shorten absolute path to last 3 components
    private static func shortenPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 3 else { return path }
        return "…/" + parts.suffix(3).joined(separator: "/")
    }

    /// Cap string length; append a note if truncated
    private static func cap(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        let remaining = s.count - max
        return String(s.prefix(max)) + "\n\n…（還有 \(remaining) 個字元未顯示）"
    }
}

// MARK: - Claude plan limits

enum ClaudePlan: String, CaseIterable {
    case auto  = "auto"
    case pro   = "pro"
    case max5  = "max5"
    case max20 = "max20"

    static let detectedLimitKey = "detectedPlanLimit"

    /// Output token limit per 5-hour rolling window.
    /// For `.auto`, the caller should check UserDefaults["detectedPlanLimit"] first.
    var outputTokenLimit: Int {
        switch self {
        case .auto:  return 44_000   // fallback until P90 detection runs
        case .pro:   return 44_000
        case .max5:  return 88_000
        case .max20: return 220_000
        }
    }

    var displayName: String {
        switch self {
        case .auto:  return "Auto-detect"
        case .pro:   return "Pro — 44K/5h"
        case .max5:  return "Max ×5 — 88K/5h"
        case .max20: return "Max ×20 — 220K/5h"
        }
    }
}

// MARK: - P90 detector output

struct P90Result: Codable {
    let p90: Int
    let p95: Int
    let maxPeak: Int
    let sampleCount: Int
    /// Average of 2nd-highest and 3rd-highest observed peaks.
    /// Far more accurate than maxPeak as a plan-limit denominator — see p90-detector.ts.
    let limitEstimate: Int
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
    /// ISO-8601 timestamp of the first assistant message (session start)
    let sessionStartISO: String?
    /// Session window in ms (always 18_000_000 = 5 hours)
    let sessionWindowMs: Double?
    /// Rolling 5-hour window token counts (for token-based quota progress bar)
    let sessionInput: Int?
    let sessionOutput: Int?
    let sessionCacheRead: Int?
    let sessionCacheCreation: Int?
    /// Cost for the rolling 5-hour window only (not all-time), in USD
    let session5hCostUSD: Double?
    /// Accumulated tokens since the last genuine human message (current task)
    let turnInput: Int?
    let turnOutput: Int?
    let turnCacheRead: Int?
    let turnCacheCreation: Int?
    /// Cost for the current task (since last human message), in USD
    let turnCostUSD: Double?

    // MARK: - Session helpers

    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var sessionStart: Date? {
        guard let iso = sessionStartISO else { return nil }
        return Self.isoFull.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    var sessionReset: Date? {
        guard let s = sessionStart, let w = sessionWindowMs else { return nil }
        return s.addingTimeInterval(w / 1000)
    }

    /// 0–1 fraction of output quota consumed in the rolling 5-hour window.
    /// Falls back to time-based progress if session token data is unavailable.
    func sessionTokenProgress(planLimit: Int) -> Double {
        if let out = sessionOutput, planLimit > 0 {
            return min(Double(out) / Double(planLimit), 1.0)
        }
        // Fallback: time-based progress
        guard let s = sessionStart, let r = sessionReset else { return 0 }
        let total   = r.timeIntervalSince(s)
        let elapsed = Date().timeIntervalSince(s)
        guard total > 0 else { return 0 }
        return min(max(elapsed / total, 0), 1)
    }

    /// "Resets in 4h 32m" or "Resetting…"
    var resetsInText: String {
        guard let r = sessionReset else { return "—" }
        let rem = r.timeIntervalSinceNow
        guard rem > 0 else { return "Resetting…" }
        let h = Int(rem) / 3600
        let m = (Int(rem) % 3600) / 60
        return h > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(m)m"
    }
}
