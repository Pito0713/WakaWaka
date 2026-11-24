import AppKit
import Foundation

/// Periodic refreshes: usage parsers, server /usage, Codex and agy quota,
/// auto-mode expiry, the session history log and P90 plan detection.
extension AppDelegate {
    // MARK: - Polling

    func startPolling() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollingTimer = t
    }

    // MARK: - Session status polling (60s, independent of approvals)

    func startSessionStatusPolling() {
        fetchSessionStatus() // immediate first fetch
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchSessionStatus()
        }
        RunLoop.main.add(t, forMode: .common)
        sessionStatusTimer = t
    }

    // MARK: - agy quota polling (5-minute interval)

    func startAgyQuotaPolling() {
        fetchAgyQuota()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.fetchAgyQuota() }
        RunLoop.main.add(t, forMode: .common)
        agyQuotaTimer = t
    }

    func fetchAgyQuota() {
        AgyQuotaService.shared.fetch { [weak self] quota in
            DispatchQueue.main.async { self?.viewModel.agyQuota = quota }
        }
    }

    // MARK: - Auto mode (per-agent, 30-min TTL, persisted to ~/.wakawaka/settings.json)

    func startAutoModePolling() {
        viewModel.onToggleAutoMode = { [weak self] agent, enabled in
            self?.setAutoMode(agent: agent, enabled: enabled)
        }
        pollAutoMode() // reconcile any already-expired state before first render
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.pollAutoMode() }
        RunLoop.main.add(t, forMode: .common)
        autoModeTimer = t
    }

    func setAutoMode(agent: AutoModeAgent, enabled: Bool) {
        SettingsService.shared.setAutoMode(agent: agent, enabled: enabled)
        viewModel.applyAutoMode(from: SettingsService.shared.load())
    }

    /// Reverts any agent whose 30-minute auto-mode window has elapsed (so the
    /// hook stops honoring it), then mirrors the resulting settings into the
    /// view model so the toggle UI always reflects what's actually on disk.
    func pollAutoMode() {
        let settings = SettingsService.shared.load()
        if settings.autoMode.claudeCode.isExpired { SettingsService.shared.setAutoMode(agent: .claudeCode, enabled: false) }
        if settings.autoMode.agy.isExpired        { SettingsService.shared.setAutoMode(agent: .agy, enabled: false) }
        if settings.autoMode.codex.isExpired      { SettingsService.shared.setAutoMode(agent: .codex, enabled: false) }
        viewModel.applyAutoMode(from: SettingsService.shared.load())
    }

    // MARK: - Server-verified usage (`claude -p "/usage"`, 10-minute interval)

    func startUsageCommandPolling() {
        fetchUsageCommand()
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            self?.fetchUsageCommand()
        }
        RunLoop.main.add(t, forMode: .common)
        usageCommandTimer = t
    }

    func fetchUsageCommand() {
        viewModel.isLoadingClaudeUsage = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ParserRunner.runClaudeUsage()
            DispatchQueue.main.async {
                guard let self else { return }
                self.viewModel.claudeUsageInfo    = result
                self.viewModel.isLoadingClaudeUsage = false
            }
        }
    }

    // MARK: - Codex account usage (local session snapshot, 10-minute interval)

    /// Context meters refresh on their own slower clock.
    ///
    /// The registry poll next door runs on the **main thread** once a second;
    /// reading a transcript per row at that rate would put file I/O in front of
    /// every click. Five seconds is far inside the time a context takes to move
    /// a percentage point, and the reader skips any file whose size and mtime
    /// are unchanged, so a quiet session costs one `stat` per pass.
    func startContextUsagePolling() {
        refreshContextUsage()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshContextUsage()
        }
        RunLoop.main.add(timer, forMode: .common)
        contextUsageTimer = timer
    }

    func refreshContextUsage() {
        let rows = viewModel.activeAgents.rows
        guard !rows.isEmpty else {
            if !viewModel.contextUsage.isEmpty { viewModel.contextUsage = [:] }
            return
        }
        contextScanGeneration += 1
        let generation = contextScanGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let usage = ContextUsageService.usage(for: rows)
            DispatchQueue.main.async {
                guard let self, generation == self.contextScanGeneration,
                      usage != self.viewModel.contextUsage else { return }
                self.viewModel.contextUsage = usage
                self.floatingPanelController?.update(contextUsage: usage)
                // Crossing into the critical band adds a line to a row, so the
                // popover has to be remeasured — setting it without resizing
                // would clip the very warning that exists to be read. This is
                // the same failure the focus-error line was fixed for.
                self.updatePopoverHeight()
            }
        }
    }

    func startCodexUsagePolling() {
        fetchCodexUsage()
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            self?.fetchCodexUsage()
        }
        RunLoop.main.add(timer, forMode: .common)
        codexUsageTimer = timer
    }

    func fetchCodexUsage() {
        viewModel.isLoadingCodexUsage = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = CodexUsageService.load()
            DispatchQueue.main.async {
                guard let self else { return }
                self.viewModel.codexUsageState = state
                self.viewModel.isLoadingCodexUsage = false
            }
        }
    }

    /// Aggregate session usage across ALL recent JSONL files in ~/.claude/projects.
    /// This correctly sums tokens from concurrent Claude Code conversations, fixing
    /// the under-count when multiple sessions are active within the same 5h window.
    func fetchSessionStatus() {
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
    func appendSessionLog(_ result: UsageOutput) {
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
    func startP90Detection() {
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
}
