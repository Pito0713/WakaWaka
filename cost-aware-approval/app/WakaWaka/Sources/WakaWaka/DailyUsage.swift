import Foundation

// MARK: - daily-usage.ts output

/// Per-day, per-agent usage emitted by `parser/daily-usage.ts`.
/// Only Claude Code and Codex are covered — agy exposes no token data.
struct DailyUsage: Decodable {
    let generatedAt: String
    let days: [DayUsage]

    /// True when no agent reported any usage in the whole window.
    var isEmpty: Bool {
        days.allSatisfy { $0.agents.claudeCode == nil && $0.agents.codex == nil }
    }
}

struct DayUsage: Decodable, Identifiable {
    let date: String          // YYYY-MM-DD, local
    let agents: Agents

    var id: String { date }

    struct Agents: Decodable {
        let claudeCode: ClaudeDay?
        let codex: CodexDay?

        enum CodingKeys: String, CodingKey {
            case claudeCode = "claude-code"
            case codex
        }
    }
}

/// Claude semantics: `uncachedInput` is `input_tokens` (already excludes cache reads).
struct ClaudeDay: Decodable {
    let uncachedInput: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int
    let costUSD: Double?

    var totalTokens: Int { uncachedInput + cacheRead + cacheWrite + output }
}

/// Codex semantics: `input_tokens` already includes cache, so the parser split it
/// into `uncachedInput` (input − cached) and `cachedInput`.
struct CodexDay: Decodable {
    let uncachedInput: Int
    let cachedInput: Int
    let output: Int
    let reasoningOutput: Int
    let costUSD: Double?

    var totalTokens: Int { uncachedInput + cachedInput + output }
}

// MARK: - Dashboard display helpers

/// Which agents the dashboard renders, in a stable order.
enum UsageAgent: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex  = "Codex"
    var id: String { rawValue }
}

/// Metric the dashboard aggregates by.
enum UsageMetric: String, CaseIterable, Identifiable {
    case cost   = "成本"
    case tokens = "Token"
    var id: String { rawValue }
    var axisLabel: String { self == .cost ? "USD" : "Tokens" }
}

extension DayUsage {
    /// Cost for an agent on this day; nil when the agent is absent OR its price is unknown.
    func cost(for agent: UsageAgent) -> Double? {
        switch agent {
        case .claude: return agents.claudeCode?.costUSD
        case .codex:  return agents.codex?.costUSD
        }
    }

    /// Total raw tokens for an agent on this day; nil when the agent is absent.
    func tokens(for agent: UsageAgent) -> Int? {
        switch agent {
        case .claude: return agents.claudeCode?.totalTokens
        case .codex:  return agents.codex?.totalTokens
        }
    }

    /// Metric value for the chart. Cost mode returns nil when the agent has no
    /// price (Codex before pricing.json is filled) so the bar is skipped, not zeroed.
    func value(for agent: UsageAgent, metric: UsageMetric) -> Double? {
        switch metric {
        case .cost:   return cost(for: agent)
        case .tokens: return tokens(for: agent).map(Double.init)
        }
    }
}
