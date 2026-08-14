import SwiftUI

/// Single source of truth for the queue popover.
/// AppDelegate mutates these; ContentView observes them.
final class PopoverViewModel: ObservableObject {
    /// All currently-waiting items (FIFO order)
    @Published var pendingItems: [PendingData] = []
    /// Which row is currently expanded (nil = all collapsed)
    @Published var expandedIndex: Int? = nil
    /// Usage data for the currently-expanded item
    @Published var usage: UsageOutput?
    @Published var isLoadingUsage: Bool = false

    /// Callbacks wired up by AppDelegate, parameterised by queue index
    /// Always-visible session status (updated every 60s independently of approvals)
    @Published var sessionStatus: UsageOutput?
    @Published var isLoadingSession: Bool = false

    /// Server-verified usage from `claude -p "/usage"` (updated every 10 min + on manual refresh)
    @Published var claudeUsageInfo: ClaudeUsageInfo? = nil
    @Published var isLoadingClaudeUsage: Bool = false
    /// Account quota snapshot from the newest local Codex token_count event.
    @Published var codexUsageState: CodexUsageState = .unavailable
    @Published var isLoadingCodexUsage: Bool = false

    /// agy quota from local language server (updated every 5 min)
    @Published var agyQuota: AgyQuota? = nil

    /// Live agent sessions, refreshed by the same 1s poll that scans for
    /// approvals. Empty is the normal state before any hooked session starts.
    @Published var activeAgents: ActiveAgentsSnapshot = .empty
    /// True while a forced re-verification is in flight (it shells out).
    @Published var isRefreshingAgents: Bool = false
    /// Why the last click could not reach a window; nil when it worked.
    @Published var agentFocusError: String? = nil

    /// Per-agent "auto mode" toggle state, mirrored from ~/.wakawaka/settings.json.
    /// AppDelegate owns the SettingsService round-trip (including the 30-min
    /// expiry sweep); this is just the UI's read-only reflection of it.
    @Published var claudeCodeAutoMode: AgentAutoMode = .disabled
    @Published var agyAutoMode:        AgentAutoMode = .disabled
    @Published var codexAutoMode:      AgentAutoMode = .disabled

    var onAllow:          (Int) -> Void = { _ in }
    var onAlwaysAllow:    (Int) -> Void = { _ in }
    var onDeny:           (Int) -> Void = { _ in }
    var onToggleExpand:   (Int) -> Void = { _ in }
    /// Dismiss an expired item (hook already gone; no decision written)
    var onDismiss:        (Int) -> Void = { _ in }
    /// Manually trigger an immediate session-status refresh (re-parses JSONL now)
    var onRefreshSession: () -> Void = {}
    /// User flipped an auto-mode toggle in the UI (keyed by agent, not queue index).
    var onToggleAutoMode: (AutoModeAgent, Bool) -> Void = { _, _ in }
    /// User tapped the "usage dashboard" button; AppDelegate opens the window.
    var onOpenDashboard: () -> Void = {}
    /// User clicked an agent row; bring its terminal to the front.
    var onFocusAgent: (ActiveAgentRow) -> Void = { _ in }
    /// User asked for an immediate liveness re-check of every agent.
    var onRefreshAgents: () -> Void = {}

    /// Mirrors a freshly-loaded settings snapshot into the published UI state.
    func applyAutoMode(from settings: WakaWakaSettings) {
        claudeCodeAutoMode = settings.autoMode.claudeCode
        agyAutoMode = settings.autoMode.agy
        codexAutoMode = settings.autoMode.codex
    }
}
