import Foundation

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

// MARK: - Server-side usage from `claude -p "/usage"`

struct ClaudeUsageInfo {
    let sessionPct: Int       // e.g. 67
    let sessionReset: Date?   // parsed from "resets Jun 20 at 5:50pm (Asia/Taipei)"
    let weeklyPct: Int?       // e.g. 10
    let weeklyReset: Date?    // parsed from the "Current week" line's "resets …"
    let fetchedAt: Date

    /// True when the data is older than 11 minutes (one polling interval missed).
    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 660 }

    static func resetsInText(from reset: Date) -> String {
        let rem = reset.timeIntervalSinceNow
        guard rem > 0 else { return "Resetting…" }
        let h = Int(rem) / 3600
        let m = (Int(rem) % 3600) / 60
        return h > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(m)m"
    }
}

// MARK: - Account quota snapshot emitted by local Codex sessions

enum CodexUsageState: Equatable {
    case available(CodexUsageInfo)
    case unavailable
    case error(String)
}

struct CodexWindowUsage: Equatable {
    let usedPercent: Int
    let windowMinutes: Int
    let resetsAt: Date?

    var windowText: String {
        guard windowMinutes > 0 else { return "Account limit" }
        if windowMinutes < 60 {
            return "\(windowMinutes)m window"
        }
        if windowMinutes.isMultiple(of: 10_080) {
            return "\(windowMinutes / 10_080)w window"
        }
        if windowMinutes.isMultiple(of: 1_440) {
            return "\(windowMinutes / 1_440)d window"
        }
        return "\(windowMinutes / 60)h window"
    }

    func resetText(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let remainingSeconds = Int(resetsAt.timeIntervalSince(now))

        // A snapshot surviving beyond its own window means the account has already
        // reset and its percentage is fictional; only a live reading can be resetting.
        guard remainingSeconds > 0 else { return "Snapshot expired" }

        let days = remainingSeconds / 86_400
        if days > 0 {
            let hours = (remainingSeconds % 86_400) / 3_600
            if hours > 0 { return "Resets in \(days)d \(hours)h" }
            let minutes = (remainingSeconds % 3_600) / 60
            return "Resets in \(days)d \(minutes)m"
        }

        let hours = remainingSeconds / 3_600
        let minutes = (remainingSeconds % 3_600) / 60
        return hours > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(minutes)m"
    }
}

struct CodexUsageInfo: Equatable {
    let primary: CodexWindowUsage
    let secondary: CodexWindowUsage?
    let fetchedAt: Date

    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 660 }

    /// Absolute local time of the reading rather than a relative age: comparing
    /// this figure between machines is the point — each one carries its own snapshot.
    func snapshotText() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return "Snapshot \(formatter.string(from: fetchedAt))"
    }
}
