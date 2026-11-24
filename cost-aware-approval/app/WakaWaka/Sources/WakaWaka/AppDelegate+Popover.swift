import AppKit

/// Popover presentation, the active-agents panel and HUD, view-model sync,
/// and writing the user's decisions back to the hooks.
extension AppDelegate {
    // MARK: - Popover

    func showUsageDashboard() {
        if dashboardController == nil {
            dashboardController = UsageDashboardWindowController()
        }
        let snapshot = LiveQuotaSnapshot(
            claudeUsage: viewModel.sessionStatus,
            claudeServer: viewModel.claudeUsageInfo,
            codex: viewModel.codexUsageState
        )
        dashboardController?.present(liveQuota: snapshot)
    }

    @objc func togglePopover() {
        // Always toggle: clicking the icon closes the popover even with pending items.
        // The user can still work in the background — the popover is non-blocking.
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(ifNewItem: false)
        }
    }

    func showPopover(ifNewItem: Bool) {
        refreshViewModel()
        updatePopoverHeight(force: true)
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // NSHostingController inside an NSPopover can come up blank on first show
            // (SwiftUI isn't asked to draw until an interaction/resize). Force a
            // layout + display pass so content paints immediately.
            if let v = popover.contentViewController?.view {
                v.needsLayout = true
                v.needsDisplay = true
                v.layoutSubtreeIfNeeded()
                v.displayIfNeeded()
            }
        }
        // Do NOT activate the app — popover floats without stealing keyboard focus
    }

    // MARK: - Active agents

    /// Brings the agent's terminal forward. Runs off the main thread because it
    /// shells out to `ps`, `tmux` and `osascript` — a few hundred milliseconds
    /// on the UI thread would freeze the popover mid-click.
    func focusAgentWindow(_ row: ActiveAgentRow) {
        setAgentFocusError(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = AgentWindowFocus.focus(row)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setAgentFocusError(outcome.message)
                // Focusing another app means this popover is no longer wanted.
                if outcome == .focused { self.popover.performClose(nil) }
            }
        }
    }

    /// The explanation is a line in the panel, so it changes the height —
    /// setting it without resizing would clip the very message that exists to
    /// tell the user what went wrong.
    func setAgentFocusError(_ message: String?) {
        guard viewModel.agentFocusError != message else { return }
        viewModel.agentFocusError = message
        floatingPanelController?.update(focusError: message)
        updatePopoverHeight()
    }

    /// Re-checks every agent immediately instead of waiting out the grace
    /// period, then republishes. The pid checks are syscalls, but the directory
    /// read is I/O, so it stays off the main thread.
    func refreshAgents() {
        guard !viewModel.isRefreshingAgents else { return }
        viewModel.isRefreshingAgents = true

        // The 1 s poll keeps running while this works. Without a generation the
        // slower background result would land last and overwrite a newer
        // snapshot, briefly resurrecting rows the poll had already dropped.
        agentScanGeneration += 1
        let generation = agentScanGeneration
        let pending = pendingQueue
        let startedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stateDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".wakawaka/state")
            var scanError: Error?
            var urls: [URL] = []
            do {
                urls = try FileManager.default.contentsOfDirectory(
                    at: stateDir, includingPropertiesForKeys: [.creationDateKey],
                    options: .skipsHiddenFiles)
            } catch {
                scanError = error
            }
            let snapshot = AgentRegistryService.snapshot(
                from: urls, pending: pending, scanError: scanError, forceVerify: true)

            DispatchQueue.main.async {
                guard let self else { return }
                // The scan is faster than the spin it triggers, so the flag is
                // lowered on a floor rather than on completion — otherwise the
                // icon never visibly turns and the click reads as ignored. It
                // is lowered whether or not this result is still current: the
                // button must not stay disabled because a newer scan won.
                let remaining = RefreshSpin.remaining(after: Date().timeIntervalSince(startedAt))
                if remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                        self?.viewModel.isRefreshingAgents = false
                    }
                } else {
                    self.viewModel.isRefreshingAgents = false
                }
                guard generation == self.agentScanGeneration else { return }
                if snapshot != self.viewModel.activeAgents {
                    self.viewModel.activeAgents = snapshot
                    self.floatingPanelController?.update(snapshot: snapshot)
                    self.updatePopoverHeight()
                }
            }
        }
    }

    // MARK: - ViewModel sync

    func restoreFloatingPanel() {
        viewModel.isFloatingPanelVisible = floatingPanelPreferences.isEnabled
        if viewModel.isFloatingPanelVisible { showFloatingPanel() }
    }

    func setFloatingPanelVisible(_ isVisible: Bool) {
        floatingPanelPreferences.isEnabled = isVisible
        viewModel.isFloatingPanelVisible = isVisible
        if isVisible {
            showFloatingPanel()
        } else {
            floatingPanelController?.hide()
        }
    }

    func showFloatingPanel() {
        if floatingPanelController == nil {
            floatingPanelController = FloatingAgentsPanelController(
                preferences: floatingPanelPreferences,
                onFocus: { [weak self] row in self?.focusAgentWindow(row) },
                // Routed through setFloatingPanelVisible rather than hide(): closing
                // from the HUD must also persist the preference and un-highlight the
                // popover's toggle, or the panel returns on the next launch and the
                // footer icon claims it is still open.
                onClose: { [weak self] in self?.setFloatingPanelVisible(false) }
            )
        }
        floatingPanelController?.update(snapshot: viewModel.activeAgents)
        floatingPanelController?.update(focusError: viewModel.agentFocusError)
        floatingPanelController?.show()
    }


    func refreshViewModel() {
        viewModel.pendingItems = pendingQueue
        updatePopoverHeight()
    }

    /// - Parameter force: measure even while the popover is closed, for the
    ///   moment just before it opens. Its size is unobservable until then, so
    ///   every other poll skips the work entirely.
    func updatePopoverHeight(force: Bool = false) {
        guard force || popover.isShown else { return }
        PopoverSizing.apply(to: popover, model: viewModel,
                            width: popoverWidth, animated: popover.isShown)
    }

    // MARK: - Decisions (any queue index)

    /// Dismiss an expired (tombstoned) item. No decision is written — the hook is already gone.
    func dismiss(at index: Int) {
        guard index < pendingQueue.count else { return }
        removePending(at: index)   // removePending will delete the pending file
    }

    func allow(at index: Int) {
        guard index < pendingQueue.count else { return }
        guard canWriteAllowDecision(for: pendingQueue[index]) else { return }
        writeDecision(#"{"decision":"allow"}"#, for: pendingQueue[index])
        removePending(at: index)
    }

    func alwaysAllow(at index: Int) {
        guard index < pendingQueue.count else { return }
        guard canWriteAlwaysAllowDecision(for: pendingQueue[index]) else { return }
        writeDecision(#"{"decision":"always"}"#, for: pendingQueue[index])
        removePending(at: index)
    }

    func deny(at index: Int) {
        guard index < pendingQueue.count else { return }
        writeDecision(#"{"decision":"deny","reason":"User denied"}"#, for: pendingQueue[index])
        removePending(at: index)
    }

    func writeDecision(_ json: String, for item: PendingData) {
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

    func removePending(at index: Int) {
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
