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

    /// agy quota from local language server (updated every 5 min)
    @Published var agyQuota: AgyQuota? = nil

    /// Per-agent "auto mode" toggle state, mirrored from ~/.wakawaka/settings.json.
    /// AppDelegate owns the SettingsService round-trip (including the 30-min
    /// expiry sweep); this is just the UI's read-only reflection of it.
    @Published var claudeCodeAutoMode: AgentAutoMode = .disabled
    @Published var agyAutoMode:        AgentAutoMode = .disabled

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

    /// Mirrors a freshly-loaded settings snapshot into the published UI state.
    func applyAutoMode(from settings: WakaWakaSettings) {
        claudeCodeAutoMode = settings.autoMode.claudeCode
        agyAutoMode = settings.autoMode.agy
    }
}
