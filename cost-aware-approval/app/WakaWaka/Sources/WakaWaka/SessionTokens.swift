import Foundation

/// How full an agent's context window is right now.
///
/// This is deliberately *not* the session's cumulative spend. The two differ by
/// an order of magnitude once prompt caching is involved — a measured Claude
/// Code turn read 228,495 cached tokens against 2 uncached ones — so cumulative
/// totals answer "what did this cost", never "how much room is left".
struct ContextUsage: Equatable {
    let usedTokens: Int
    let limitTokens: Int

    /// Fails rather than defaulting when either number cannot carry a
    /// percentage. A meter with no denominator must not be drawn at all: an
    /// empty bar reads the same as a genuinely empty context, and the user has
    /// no way to tell "0% used" from "we could not find out".
    init?(usedTokens: Int, limitTokens: Int) {
        guard limitTokens > 0, usedTokens >= 0 else { return nil }
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
    }

    /// Clamped at 1. A model reporting more than its own stated window means
    /// the window is wrong — a provider change, a stale table — and "104%" puts
    /// that confusion on screen for the user to decode.
    var fraction: Double {
        min(Double(usedTokens) / Double(limitTokens), 1)
    }

    var percent: Int {
        Int((fraction * 100).rounded())
    }

    /// Derived from the **displayed** percent, not from the raw fraction, so a
    /// row can never show "85%" in the colour that means "below 85".
    var band: ContextBand {
        ContextBand(percent: percent)
    }
}

/// Which warning band a context sits in.
enum ContextBand: Equatable {
    case normal
    case warning
    case critical

    /// Provisional values. A threshold is worth exactly as much as the warning
    /// it gives before auto-compaction removes the choice, and that trigger
    /// point has not been measured yet — see `session-token-plan.md` §六.
    /// Changing these is expected; changing them without measuring is not.
    static let warningPercent = 70
    static let criticalPercent = 85

    init(percent: Int) {
        switch percent {
        case ContextBand.criticalPercent...: self = .critical
        case ContextBand.warningPercent...:  self = .warning
        default:                             self = .normal
        }
    }
}
