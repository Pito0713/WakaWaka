import AppKit
import UserNotifications

/// The 1-second approval-queue poll, usage notifications and the
/// per-session usage cache behind the expanded row.
extension AppDelegate {
    // MARK: - Notifications

    /// UNUserNotificationCenter requires a proper app bundle (.app with Info.plist).
    /// When running directly from .build/debug (SwiftPM dev build), skip gracefully.
    var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Called after each session status refresh to fire 80% / 95% warnings.
    func checkUsageNotifications(usage: UsageOutput) {
        let manual   = UserDefaults.standard.integer(forKey: "manualPlanLimit")
        let detected = UserDefaults.standard.integer(forKey: ClaudePlan.detectedLimitKey)
        let limit    = manual > 1_000 ? manual : detected > 1_000 ? detected : 44_000
        guard limit > 0, let out = usage.sessionOutput else { return }

        let progress = Double(out) / Double(limit)
        let pct      = Int(progress * 100)

        // Reset threshold tracking when the 5-hour quota window genuinely rolls over.
        // With the sliding-window algorithm, sessionStartISO advances gradually as old
        // entries age out — so we only clear thresholds when output has actually dropped
        // (i.e. the window truly reset), not merely because sessionStartISO ticked forward.
        if usage.sessionStartISO != notifiedWindowISO {
            notifiedWindowISO = usage.sessionStartISO
            if progress < 0.15 {
                notifiedThresholds = []
            }
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
    func sendUrgentNotification(count: Int) {
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

    func isValidSessionId(_ sid: String) -> Bool {
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !sid.isEmpty && sid.unicodeScalars.allSatisfy { ok.contains($0) }
    }

    func poll() {
        let stateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wakawaka/state")

        // The failure is kept, not discarded: an unreadable state directory and
        // an empty one produce the same list, and the agents panel has to be
        // able to tell the user which one it is looking at.
        var scanError: Error?
        var urls: [URL] = []
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: stateDir, includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles)
        } catch {
            scanError = error
        }

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

        // Active-agents panel: the registry files sit in the directory just
        // enumerated, so this reuses that listing rather than walking again.
        // Placed before the early return below — that guard only covers the
        // approval queue, and skipping it here would freeze the panel.
        agentScanGeneration += 1
        let agents = AgentRegistryService.snapshot(from: urls, pending: newQueue, scanError: scanError)
        if agents != viewModel.activeAgents {
            viewModel.activeAgents = agents
            floatingPanelController?.update(snapshot: agents)
            // The approval queue may be unchanged, in which case this method
            // returns below without refreshing anything — so resize here or the
            // panel grows inside a popover that stays its old size.
            updatePopoverHeight()
        }

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

    func fetchUsage(for index: Int) {
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

    func toggleExpand(_ index: Int) {
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
}
