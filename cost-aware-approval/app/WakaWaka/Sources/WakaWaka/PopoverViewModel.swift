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

    var onAllow:          (Int) -> Void = { _ in }
    var onAlwaysAllow:    (Int) -> Void = { _ in }
    var onDeny:           (Int) -> Void = { _ in }
    var onToggleExpand:   (Int) -> Void = { _ in }
    /// Dismiss an expired item (hook already gone; no decision written)
    var onDismiss:        (Int) -> Void = { _ in }
    /// Manually trigger an immediate session-status refresh (re-parses JSONL now)
    var onRefreshSession: () -> Void = {}
}
