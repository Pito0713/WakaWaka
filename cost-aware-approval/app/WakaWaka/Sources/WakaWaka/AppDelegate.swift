import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var pollingTimer: Timer?

    private let viewModel = PopoverViewModel()
    private var pendingQueue: [PendingData] = []

    // Per-session usage cache (avoid re-fetching if user collapses/expands)
    // Per-session approval usage cache
    private var usageCache:       [String: UsageOutput] = [:]
    private var loadingSessions:  Set<String> = []

    // Session status (always-visible bar)
    private var sessionStatusTimer: Timer?

    // Notification tracking: avoid re-firing within the same session window
    private var notifiedWindowISO: String?
    private var notifiedThresholds: Set<Int> = []

    // Ghost icon animation
    private var animFrame = 0
    private var iconTimer: Timer?

    // Serial queue for session-log.jsonl writes — prevents interleaved appends
    // when two timer fires overlap (concurrent utility queue).
    private let logQueue = DispatchQueue(label: "wakawaka.sessionlog")
    private static let isoFormatter = ISO8601DateFormatter()

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()
        setupPopover()
        startPolling()
        startSessionStatusPolling()
        startP90Detection()
        requestNotificationPermission()
        startIconAnimation()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(hasPending: false)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
    }

    private func setupPopover() {
        // Wire callbacks — index-based so any queue item can be acted on
        viewModel.onAllow          = { [weak self] i in self?.allow(at: i) }
        viewModel.onAlwaysAllow    = { [weak self] i in self?.alwaysAllow(at: i) }
        viewModel.onDeny           = { [weak self] i in self?.deny(at: i) }
        viewModel.onToggleExpand   = { [weak self] i in self?.toggleExpand(i) }
        viewModel.onDismiss        = { [weak self] i in self?.dismiss(at: i) }
        viewModel.onRefreshSession = { [weak self] in self?.fetchSessionStatus() }

        popover = NSPopover()
        popover.behavior = .applicationDefined

        let hc = NSHostingController(rootView: ContentView(model: viewModel))
        // Disable automatic sizing so our contentSize is respected
        if #available(macOS 13.0, *) { hc.sizingOptions = [] }
        popover.contentViewController = hc
        popover.contentSize = NSSize(width: 480, height: 100)
    }

    private func setIcon(hasPending: Bool) {
        guard let button = statusItem.button else { return }
        button.image = makeGhostIcon(hasPending: hasPending)
        button.contentTintColor = nil
        button.title = ""
    }

    // MARK: - Pixel ghost animation

    /// Ghost pixel maps: 0 = transparent, 1 = body (auto dark/light), 2 = eye (transparent cutout)
    /// Two frames alternate the bottom wave → classic Pac-Man ghost float
    private static let ghostFrames: [[[Int]]] = [
        [   // Frame 0 — wave A
            [0,0,1,1,1,1,1,0,0],
            [0,1,1,1,1,1,1,1,0],
            [1,1,1,1,1,1,1,1,1],
            [1,2,2,1,1,1,2,2,1],   // eyes
            [1,2,2,1,1,1,2,2,1],   // eyes
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,0,1,1,0,1,1,0],   // bottom wave A
            [1,0,0,1,0,0,1,0,0],
        ],
        [   // Frame 1 — wave B (shifted one pixel right)
            [0,0,1,1,1,1,1,0,0],
            [0,1,1,1,1,1,1,1,0],
            [1,1,1,1,1,1,1,1,1],
            [1,2,2,1,1,1,2,2,1],
            [1,2,2,1,1,1,2,2,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,0,1,1,0,1,1,0,1],   // bottom wave B
            [0,0,1,0,0,1,0,0,1],
        ],
    ]

    private func startIconAnimation() {
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.animFrame = (self.animFrame + 1) % 2
            self.setIcon(hasPending: !self.pendingQueue.isEmpty)
        }
        RunLoop.main.add(t, forMode: .common)
        iconTimer = t
    }

    private func makeGhostIcon(hasPending: Bool) -> NSImage {
        let px: CGFloat  = 1.53        // each ghost pixel (~25% smaller than original 2pt)
        let cols         = 9
        let rows         = 10
        let canvasW      = CGFloat(cols) * px  // 18 pt
        let canvasH: CGFloat = 22
        let offsetY      = (canvasH - CGFloat(rows) * px) / 2  // vertical centre = 1 pt
        let pixels       = Self.ghostFrames[animFrame]
        let canvas       = NSSize(width: canvasW, height: canvasH)

        let img = NSImage(size: canvas, flipped: false) { [weak self] rect in
            guard let self else { return true }

            // Body colour adapts to current appearance
            let isDark = NSApp.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bodyColor: NSColor = isDark ? .white : .black

            for row in 0..<rows {
                for col in 0..<cols {
                    guard pixels[row][col] == 1 else { continue }
                    let x = CGFloat(col) * px
                    let y = offsetY + CGFloat(rows - 1 - row) * px  // row 0 = top
                    bodyColor.setFill()
                    NSBezierPath(rect: NSRect(x: x, y: y, width: px, height: px)).fill()
                }
            }

            // Pending dot: orange circle, top-right, pulses with frame
            if hasPending {
                let alpha: CGFloat = self.animFrame == 0 ? 1.0 : 0.5
                NSColor.systemOrange.withAlphaComponent(alpha).setFill()
                let r: CGFloat = 4
                NSBezierPath(ovalIn: NSRect(
                    x: rect.width  - r - 0.5,
                    y: rect.height - r - 0.5,
                    width: r, height: r
                )).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    // MARK: - Polling

    private func startPolling() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollingTimer = t
    }

    // MARK: - Session status polling (60s, independent of approvals)

    private func startSessionStatusPolling() {
        fetchSessionStatus() // immediate first fetch
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchSessionStatus()
        }
        RunLoop.main.add(t, forMode: .common)
        sessionStatusTimer = t
    }

    /// Aggregate session usage across ALL recent JSONL files in ~/.claude/projects.
    /// This correctly sums tokens from concurrent Claude Code conversations, fixing
    /// the under-count when multiple sessions are active within the same 5h window.
    private func fetchSessionStatus() {
        viewModel.isLoadingSession = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ParserRunner.runAggregated()
            // Append a log entry for historical comparison/backtesting (I/O stays on background thread)
            if let r = result { self?.appendSessionLog(r) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.viewModel.sessionStatus   = result
                self.viewModel.isLoadingSession = false
                if let r = result { self.checkUsageNotifications(usage: r) }
                self.refreshViewModel()
            }
        }
    }

    // MARK: - Session history logging

    /// Appends one JSON-Lines record to ~/.wakawaka/session-log.jsonl on every
    /// periodic fetch.  The file accumulates a timestamped trail of WakaWaka
    /// readings so they can be compared against Claude Desktop's % later for
    /// accuracy analysis and backtesting.
    ///
    /// Schema (one JSON object per line):
    ///   ts           – ISO-8601 fetch timestamp
    ///   sessionOutput – output tokens counted in the current 5h window
    ///   limit        – denominator used for % (manual > detected > 44000)
    ///   pct          – sessionOutput / limit × 100 (one decimal)
    ///   sessionStart – ISO-8601 start of the detected 5h window
    ///   windowEnd    – ISO-8601 end of the detected 5h window
    private func appendSessionLog(_ result: UsageOutput) {
        guard let sessionOutput = result.sessionOutput else { return }

        // Use the same limit-priority logic as checkUsageNotifications
        let manual   = UserDefaults.standard.integer(forKey: "manualPlanLimit")
        let detected = UserDefaults.standard.integer(forKey: ClaudePlan.detectedLimitKey)
        let limit    = manual > 1_000 ? manual : detected > 1_000 ? detected : 44_000

        let pct = Double(sessionOutput) / Double(limit) * 100.0

        var entry: [String: Any] = [
            "ts":            Self.isoFormatter.string(from: Date()),
            "sessionOutput": sessionOutput,
            "limit":         limit,
            "pct":           String(format: "%.1f", pct),
        ]
        if let start = result.sessionStartISO { entry["sessionStart"] = start }
        if let reset = result.sessionReset    { entry["windowEnd"]    = Self.isoFormatter.string(from: reset) }

        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else { return }

        // Dispatch file I/O to serial queue — prevents seekToEnd+write interleaving
        // if two fetches overlap on the concurrent utility queue.
        logQueue.async {
            let home    = FileManager.default.homeDirectoryForCurrentUser
            let dir     = home.appendingPathComponent(".wakawaka")
            let logFile = dir.appendingPathComponent("session-log.jsonl")

            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)

            if FileManager.default.fileExists(atPath: logFile.path) {
                if let fh = try? FileHandle(forWritingTo: logFile) {
                    defer { try? fh.close() }
                    fh.seekToEndOfFile()
                    fh.write(lineData)
                }
            } else {
                try? lineData.write(to: logFile, options: .atomic)
            }
        }
    }

    // MARK: - P90 auto-detection

    /// Runs the P90 detector in the background on startup.
    /// Stores result in UserDefaults["detectedPlanLimit"] — @AppStorage in views will react automatically.
    ///
    /// Uses `limitEstimate` (average of 2nd-highest and 3rd-highest session peaks) as the
    /// plan-limit denominator, which is far more accurate than maxPeak alone.
    ///
    /// Rationale: the absolute maximum peak often reflects an overage session that exceeded
    /// the quota ceiling (e.g. maxPeak=196K when the true limit ≈178K gives 8% error).
    /// The 2nd and 3rd highest peaks straddle the actual plan limit (one slightly above,
    /// one slightly below), so their average typically lands within 0–2% of the true limit.
    /// P90 of peaks is ~70–80% of the limit (users rarely fill the whole window), making it
    /// a poor denominator — so the old p90 approach is also discarded.
    ///
    /// The user can override via manual calibration (⚡ badge → tap → enter Claude Desktop %).
    private func startP90Detection() {
        DispatchQueue.global(qos: .background).async {
            guard let result = ParserRunner.runP90Detector() else { return }
            // Sanity checks: need meaningful data, reject obviously wrong values
            guard result.sampleCount >= 5 else { return }
            // Use limitEstimate (avg of 2nd & 3rd highest peaks) as the plan-limit denominator.
            // maxPeak can exceed the true quota by ~10% when a session has overages; the
            // limitEstimate formula cancels out that outlier and consistently approximates
            // the actual Claude plan ceiling within ~1% (vs ~8% error with maxPeak alone).
            // Prefer limitEstimate; do NOT fall back to maxPeak (which has ~8% overage error).
            // If limitEstimate is missing/invalid, skip storing — views will keep the previous
            // detected value or the 44K fallback rather than getting a known-bad denominator.
            guard result.limitEstimate > 5_000 && result.limitEstimate < 5_000_000 else { return }
            let limit = result.limitEstimate
            // Always update detectedPlanLimit from fresh detection — even if the
            // user has a manualPlanLimit set.  The display logic (ContentView, notifications)
            // already gives manualPlanLimit priority over detectedPlanLimit, so overwriting
            // the detected value here never affects a manually-calibrated display.
            DispatchQueue.main.async {
                UserDefaults.standard.set(limit, forKey: ClaudePlan.detectedLimitKey)
            }
        }
    }

    // MARK: - Notifications

    /// UNUserNotificationCenter requires a proper app bundle (.app with Info.plist).
    /// When running directly from .build/debug (SwiftPM dev build), skip gracefully.
    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Called after each session status refresh to fire 80% / 95% warnings.
    private func checkUsageNotifications(usage: UsageOutput) {
        let manual   = UserDefaults.standard.integer(forKey: "manualPlanLimit")
        let detected = UserDefaults.standard.integer(forKey: ClaudePlan.detectedLimitKey)
        let limit    = manual > 1_000 ? manual : detected > 1_000 ? detected : 44_000
        guard limit > 0, let out = usage.sessionOutput else { return }

        let progress = Double(out) / Double(limit)
        let pct      = Int(progress * 100)

        // Reset tracking when session window rolls over
        if usage.sessionStartISO != notifiedWindowISO {
            notifiedWindowISO  = usage.sessionStartISO
            notifiedThresholds = []
        }

        let thresholds: [(Int, String, String)] = [
            (80, "⚠️ Claude 用量 80%",
             "近 5h 已用 \(pct)%（\(out / 1000)K / \(limit / 1000)K output tokens）"),
            (95, "🚨 Claude 用量 95%",
             "即將達上限！\(pct)% 已用（\(out / 1000)K / \(limit / 1000)K output tokens）"),
        ]

        guard notificationsAvailable else { return }
        for (threshold, title, body) in thresholds where pct >= threshold && !notifiedThresholds.contains(threshold) {
            notifiedThresholds.insert(threshold)
            let content       = UNMutableNotificationContent()
            content.title     = title
            content.body      = body
            content.sound     = .default
            let request = UNNotificationRequest(
                identifier: "wakawaka_usage_\(threshold)",
                content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }

    /// Fires a system notification when one or more pending items enter urgent mode
    /// (hook has been waiting 8 minutes; auto-deny fires in ~2 minutes).
    private func sendUrgentNotification(count: Int) {
        guard notificationsAvailable else { return }
        let content   = UNMutableNotificationContent()
        content.title = "⚠️ WakaWaka 審批即將到期"
        content.body  = count == 1
            ? "有 1 個工具操作將在 2 分鐘內自動拒絕，請開啟 WakaWaka 審批"
            : "有 \(count) 個工具操作將在 2 分鐘內自動拒絕，請開啟 WakaWaka 審批"
        content.sound = .defaultCritical
        let request = UNNotificationRequest(
            identifier: "wakawaka_urgent_\(Date().timeIntervalSince1970)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func isValidSessionId(_ sid: String) -> Bool {
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !sid.isEmpty && sid.unicodeScalars.allSatisfy { ok.contains($0) }
    }

    private func poll() {
        let stateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wakawaka/state")

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles)) ?? []

        let isoParser: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        let newQueue: [PendingData] = urls
            .filter { $0.lastPathComponent.hasPrefix("pending_") && $0.lastPathComponent.hasSuffix(".json") }
            .compactMap { url -> (PendingData, Date)? in
                guard let data    = try? Data(contentsOf: url),
                      let pending = try? JSONDecoder().decode(PendingData.self, from: data),
                      let sid     = pending.session_id, isValidSessionId(sid)
                else { return nil }

                // Auto-dismiss tombstones older than 30s (hook already gone, tool NOT executed)
                if pending.isExpired, let exitedAtISO = pending.hookExitedAt {
                    let exitedAt = isoParser.date(from: exitedAtISO)
                        ?? ISO8601DateFormatter().date(from: exitedAtISO)
                        ?? .distantPast
                    if Date().timeIntervalSince(exitedAt) > 30 {
                        try? FileManager.default.removeItem(at: url)
                        return nil   // silently remove
                    }
                }

                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return (pending, date)
            }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }

        typealias Snap = (sid: String, ts: String, urgent: Bool)
        let newSnaps: [Snap] = newQueue.map    { ($0.session_id ?? "", $0.timestamp ?? "", $0.hookUrgent ?? false) }
        let oldSnaps: [Snap] = pendingQueue.map { ($0.session_id ?? "", $0.timestamp ?? "", $0.hookUrgent ?? false) }
        guard !zip(newSnaps, oldSnaps).allSatisfy({ $0 == $1 }) || newSnaps.count != oldSnaps.count
        else { return }

        let prevSids = Set(pendingQueue.compactMap { $0.session_id })

        // Detect items that just flipped to urgent (hook reached 8-min warn threshold)
        let prevUrgentSids = Set(pendingQueue.filter { $0.hookUrgent == true }.compactMap { $0.session_id })
        let newUrgentSids  = Set(newQueue.filter     { $0.hookUrgent == true }.compactMap { $0.session_id })
        let newlyUrgent    = newUrgentSids.subtracting(prevUrgentSids)

        pendingQueue = newQueue
        let currSids = Set(pendingQueue.compactMap { $0.session_id })

        // Auto-expand first NEW item if nothing is expanded
        let newSids = currSids.subtracting(prevSids)
        if !newSids.isEmpty && viewModel.expandedIndex == nil {
            if let firstNewIdx = pendingQueue.firstIndex(where: {
                guard let s = $0.session_id else { return false }
                return newSids.contains(s)
            }) {
                viewModel.expandedIndex = firstNewIdx
            }
        }

        // Clamp expanded index if queue shrank
        if let exp = viewModel.expandedIndex, exp >= pendingQueue.count {
            viewModel.expandedIndex = pendingQueue.isEmpty ? nil : pendingQueue.count - 1
        }

        if pendingQueue.isEmpty {
            setIcon(hasPending: false)
            popover.performClose(nil)
        } else {
            setIcon(hasPending: true)
            if let exp = viewModel.expandedIndex { fetchUsage(for: exp) }
            // Auto-open popover for newly-urgent items AND for new items
            if !newlyUrgent.isEmpty {
                showPopover(ifNewItem: false)
                sendUrgentNotification(count: newlyUrgent.count)
            } else {
                showPopover(ifNewItem: !newSids.isEmpty)
            }
        }

        refreshViewModel()
    }

    // MARK: - Usage (per-session cache)

    private func fetchUsage(for index: Int) {
        guard index < pendingQueue.count else { return }
        let item = pendingQueue[index]
        guard let sid = item.session_id else { return }

        // Already cached?
        if let cached = usageCache[sid] {
            viewModel.usage = cached
            viewModel.isLoadingUsage = false
            return
        }
        // Already loading?
        guard !loadingSessions.contains(sid) else { return }
        guard let transcriptPath = item.transcript_path else {
            viewModel.usage = nil
            viewModel.isLoadingUsage = false
            return
        }

        loadingSessions.insert(sid)
        viewModel.isLoadingUsage = true
        viewModel.usage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ParserRunner.run(transcriptPath: transcriptPath)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingSessions.remove(sid)
                if let r = result { self.usageCache[sid] = r }
                // Only update UI if this item is still the expanded one
                if let exp = self.viewModel.expandedIndex,
                   exp < self.pendingQueue.count,
                   self.pendingQueue[exp].session_id == sid {
                    self.viewModel.usage         = result
                    self.viewModel.isLoadingUsage = false
                }
            }
        }
    }

    // MARK: - Expand / collapse

    private func toggleExpand(_ index: Int) {
        if viewModel.expandedIndex == index {
            viewModel.expandedIndex = nil
            viewModel.usage = nil
        } else {
            viewModel.expandedIndex = index
            viewModel.usage = nil
            fetchUsage(for: index)
        }
        refreshViewModel()
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        // Always toggle: clicking the icon closes the popover even with pending items.
        // The user can still work in the background — the popover is non-blocking.
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(ifNewItem: false)
        }
    }

    private func showPopover(ifNewItem: Bool) {
        refreshViewModel()
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        // Do NOT activate the app — popover floats without stealing keyboard focus
    }

    // MARK: - ViewModel sync

    private func refreshViewModel() {
        viewModel.pendingItems = pendingQueue

        // Animate height change
        // session status bar: divider(1) + label(20) + bar(18) + burn+cost row(18) + padding(18) = ~82
        let sessionH: CGFloat = 82
        let targetH: CGFloat = pendingQueue.isEmpty
            ? 100 + sessionH
            : min(CGFloat(100 + pendingQueue.count * 52) + (viewModel.expandedIndex != nil ? 340 : 0) + sessionH, 600)

        if abs(popover.contentSize.height - targetH) > 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                popover.contentSize = NSSize(width: 480, height: targetH)
            }
        }
    }

    // MARK: - Decisions (any queue index)

    /// Dismiss an expired (tombstoned) item. No decision is written — the hook is already gone.
    func dismiss(at index: Int) {
        guard index < pendingQueue.count else { return }
        removePending(at: index)   // removePending will delete the pending file
    }

    func allow(at index: Int) {
        guard index < pendingQueue.count else { return }
        // Safety: don't write a decision for expired items (hook can't read it)
        guard !pendingQueue[index].isExpired else { removePending(at: index); return }
        writeDecision(#"{"decision":"allow"}"#, for: pendingQueue[index])
        removePending(at: index)
    }

    func alwaysAllow(at index: Int) {
        guard index < pendingQueue.count else { return }
        writeDecision(#"{"decision":"always"}"#, for: pendingQueue[index])
        removePending(at: index)
    }

    func deny(at index: Int) {
        guard index < pendingQueue.count else { return }
        writeDecision(#"{"decision":"deny","reason":"User denied"}"#, for: pendingQueue[index])
        removePending(at: index)
    }

    private func writeDecision(_ json: String, for item: PendingData) {
        guard let sid = item.session_id, isValidSessionId(sid) else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wakawaka/state/decision_\(sid).json")
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            fputs("[WakaWaka] ERROR writing decision_\(sid).json: \(error)\n", stderr)
        }
    }

    private func removePending(at index: Int) {
        guard index < pendingQueue.count else { return }
        let item = pendingQueue[index]

        // Delete the pending file
        if let sid = item.session_id, isValidSessionId(sid) {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".wakawaka/state/pending_\(sid).json")
            try? FileManager.default.removeItem(at: url)
            usageCache.removeValue(forKey: sid)
        }

        pendingQueue.remove(at: index)

        // Update expandedIndex after removal
        if let exp = viewModel.expandedIndex {
            if exp == index {
                // Removed the expanded item → try to expand next, else previous
                if pendingQueue.isEmpty {
                    viewModel.expandedIndex = nil
                    viewModel.usage = nil
                } else {
                    let newIdx = min(index, pendingQueue.count - 1)
                    viewModel.expandedIndex = newIdx
                    viewModel.usage = nil
                    fetchUsage(for: newIdx)
                }
            } else if exp > index {
                viewModel.expandedIndex = exp - 1  // shift down
            }
        }

        if pendingQueue.isEmpty {
            setIcon(hasPending: false)
            popover.performClose(nil)
        } else {
            setIcon(hasPending: true)
        }

        refreshViewModel()
    }
}
