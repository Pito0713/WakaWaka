import AppKit
import SwiftUI
import UserNotifications

func canWriteAllowDecision(for item: PendingData) -> Bool {
    item.canBeAllowed
}

func canWriteAlwaysAllowDecision(for item: PendingData) -> Bool {
    guard item.canBeAllowed, item.risk_level == .medium else { return false }
    return item.tool_name == "Bash"
        || item.tool_name == "run_command"
        || item.tool_name == "run_shell_command"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var dashboardController: UsageDashboardWindowController?
    var floatingPanelController: FloatingAgentsPanelController?
    let floatingPanelPreferences = FloatingPanelPreferences()
    var pollingTimer: Timer?

    let viewModel = PopoverViewModel()
    /// Bumped by every agent scan so a slow one cannot overwrite a newer result.
    var agentScanGeneration = 0
    var pendingQueue: [PendingData] = []

    // Per-session usage cache (avoid re-fetching if user collapses/expands)
    // Per-session approval usage cache
    var usageCache:       [String: UsageOutput] = [:]
    var loadingSessions:  Set<String> = []

    // Session status (always-visible bar)
    var sessionStatusTimer: Timer?
    // Server-verified usage via `claude -p "/usage"` (10-minute interval)
    var usageCommandTimer: Timer?
    var codexUsageTimer: Timer?
    var contextUsageTimer: Timer?
    /// Same guard the manual agent refresh uses: a slow pass must not
    /// land after a newer one and walk the meters backwards.
    var contextScanGeneration = 0
    // agy quota (5-minute interval)
    var agyQuotaTimer: Timer?
    // Auto-mode expiry sweep (30-second interval)
    var autoModeTimer: Timer?

    // Notification tracking: avoid re-firing within the same session window
    var notifiedWindowISO: String?
    var notifiedThresholds: Set<Int> = []

    // Ghost icon animation
    var animFrame = 0
    var iconTimer: Timer?

    // Serial queue for session-log.jsonl writes — prevents interleaved appends
    // when two timer fires overlap (concurrent utility queue).
    let logQueue = DispatchQueue(label: "wakawaka.sessionlog")
    static let isoFormatter = ISO8601DateFormatter()

    func applicationDidFinishLaunching(_ note: Notification) {
        SkinManager.shared.reload()   // pick up any user skin before first render
        setupStatusItem()
        setupPopover()
        restoreFloatingPanel()
        startPolling()
        startSessionStatusPolling()
        startUsageCommandPolling()
        startCodexUsagePolling()
        startContextUsagePolling()
        startAgyQuotaPolling()
        startAutoModePolling()
        startP90Detection()
        requestNotificationPermission()
        updateIconAnimationSpeed(hasPending: false)
    }

    // MARK: - Setup

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Set the invariant button properties ONCE — re-setting them every animation
        // tick forces needless redraws that can flicker.
        statusItem.button?.title = ""
        statusItem.button?.contentTintColor = nil
        statusItem.button?.imageScaling = .scaleNone
        // Force layer-backing so the CATransaction(setDisableActions) in setIcon
        // actually suppresses the implicit image cross-fade — without a layer that
        // transaction is a no-op and each frame swap can flash during recompositing.
        statusItem.button?.wantsLayer = true
        statusItem.button?.layer?.actions = ["contents": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(), "sublayers": NSNull(), "opacity": NSNull()]
        // Render the icon in a CALayer we own instead of `button.image`. Swapping
        // `button.image` each frame goes through NSButton's image-compositing path,
        // which recomposites the whole status item and can flash white on some Macs.
        // A sublayer swaps its `contents` directly on the render server — instant,
        // no implicit cross-fade, off the button-image path entirely.
        let l = CALayer()
        // .resizeAspect makes the drawn size follow the layer's bounds (not
        // contentsScale), so the icon can't blow up to raw pixel size if
        // backingScaleFactor is momentarily 1 before the window attaches.
        l.contentsGravity = .resizeAspect
        l.contentsScale = statusItem.button?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        l.actions = ["contents": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        statusItem.button?.layer?.addSublayer(l)
        iconLayer = l
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        setIcon(hasPending: false)
    }

    func setupPopover() {
        // Wire callbacks — index-based so any queue item can be acted on
        viewModel.onAllow          = { [weak self] i in self?.allow(at: i) }
        viewModel.onAlwaysAllow    = { [weak self] i in self?.alwaysAllow(at: i) }
        viewModel.onDeny           = { [weak self] i in self?.deny(at: i) }
        viewModel.onToggleExpand   = { [weak self] i in self?.toggleExpand(i) }
        viewModel.onDismiss        = { [weak self] i in self?.dismiss(at: i) }
        viewModel.onRefreshSession = { [weak self] in
            self?.fetchSessionStatus()
            self?.fetchUsageCommand()
            self?.fetchCodexUsage()
        }
        viewModel.onOpenDashboard = { [weak self] in self?.showUsageDashboard() }
        viewModel.onToggleFloatingPanel = { [weak self] visible in self?.setFloatingPanelVisible(visible) }
        viewModel.onFocusAgent    = { [weak self] row in self?.focusAgentWindow(row) }
        viewModel.onRefreshAgents = { [weak self] in self?.refreshAgents() }

        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.delegate = self

        let hc = NSHostingController(rootView: ContentView(model: viewModel))
        // Disable automatic sizing so our contentSize is respected
        if #available(macOS 13.0, *) { hc.sizingOptions = [] }
        popover.contentViewController = hc
        popover.contentSize = NSSize(width: popoverWidth, height: 100)

        // Warm up the hosting view so the first popover show paints content
        // immediately instead of flashing an empty white frame.
        hc.view.wantsLayer = true
        hc.view.layoutSubtreeIfNeeded()
    }


    var idleAction: IdleAction = .normal
    var idleActionTicks: Int = 0        // remaining ticks to hold a transient pose (blink)
    var scanTick: Int = 0               // drives the pending eye-scan cycle
    weak var lastIconImage: NSImage?   // skip redundant status-button updates
    var iconLayer: CALayer?            // hosts the icon; swapped via `contents` (off the button.image path)
    var lastLength: CGFloat = -1        // last status-item width we set

    // Feet-wave frame swap. Swaps via `iconLayer.contents` (not `button.image`), so
    // it no longer hits the recompositing path that used to flash white.
    let waveEnabled = true
    // Feet glide as a seamless conveyor: the skirt notches shift 1px per phase and
    // repeat every `feetPhaseCount` frames (idle_0…idle_4), so cycling looks like a
    // smooth continuous slide rather than a two-frame flip.
    let feetPhaseCount = 5

    var currentAnimSpeed: TimeInterval = 0.0
    let popoverWidth: CGFloat = 480
}

// MARK: - Popover visibility

extension AppDelegate: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        viewModel.isPopoverShown = true
    }

    func popoverDidClose(_ notification: Notification) {
        viewModel.isPopoverShown = false
    }
}
