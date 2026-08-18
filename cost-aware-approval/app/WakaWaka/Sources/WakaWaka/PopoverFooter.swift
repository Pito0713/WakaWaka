import SwiftUI

/// Compact, always-visible popover footer shared by both the idle and the
/// pending-approval states. Keeps only the at-a-glance controls; anything that
/// belongs to detailed inspection now lives in the standalone usage dashboard.
///
///   Row 1  — per-agent auto-mode toggles (with TTL countdown) + 📊 / ↻ actions
///   Row 2  — Claude 5h quota bar
///   Row 3  — Codex 7d quota bar
///
/// This view mutates only local UI mirrors before forwarding user intent through
/// callbacks. Progress-bar styling mirrors SessionStatusView (which stays the
/// source of the detailed dashboard) but is duplicated to keep the footer minimal.
struct PopoverFooter: View {
    @ObservedObject var model: PopoverViewModel

    @AppStorage(ClaudePlan.detectedLimitKey) private var detectedLimit: Int = 0
    @AppStorage("manualPlanLimit")           private var manualLimit:   Int = 0

    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                autoRow
                Divider().padding(.vertical, 2)
                claudeBar
                codexBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            // The usage bars are the last thing in the popover; without a
            // little more room underneath they read as clipped rather than
            // finished.
            .padding(.bottom, 16)
        }
    }

    // MARK: - Auto-mode row

    private var autoRow: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 14) {
                Text("Auto")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                agentToggle(label: "Claude", agent: .claudeCode, state: model.claudeCodeAutoMode, now: context.date)
                agentToggle(label: "agy",    agent: .agy,        state: model.agyAutoMode,        now: context.date)
                agentToggle(label: "Codex",  agent: .codex,      state: model.codexAutoMode,      now: context.date)
                Spacer()
                floatingPanelButton
                dashboardButton
                refreshButton
            }
        }
    }

    @ViewBuilder
    private func agentToggle(label: String, agent: AutoModeAgent, state: AgentAutoMode, now: Date) -> some View {
        HStack(spacing: 5) {
            Toggle(isOn: Binding(
                get: { state.enabled },
                set: { model.onToggleAutoMode(agent, $0) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Text(label).font(.caption)

            if let remaining = remainingText(state: state, now: now) {
                Text(remaining)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "↻ 27m" while the auto window is live; nil once disabled or expired.
    private func remainingText(state: AgentAutoMode, now: Date) -> String? {
        guard state.enabled, let expiresAtStr = state.expiresAt,
              let expiry = SettingsService.parseExpiry(expiresAtStr)
        else { return nil }
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return "↻ \(Int(remaining) / 60)m"
    }

    private var dashboardButton: some View {
        Button {
            model.onOpenDashboard()
        } label: {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("每日用量儀表板")
    }

    private var floatingPanelButton: some View {
        Button {
            let isVisible = !model.isFloatingPanelVisible
            model.isFloatingPanelVisible = isVisible
            model.onToggleFloatingPanel(isVisible)
        } label: {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.isFloatingPanelVisible ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(model.isFloatingPanelVisible ? "關閉懸浮 Agent 面板" : "開啟懸浮 Agent 面板")
    }

    private var refreshButton: some View {
        Button {
            guard !isRefreshing else { return }
            isRefreshing = true
            model.onRefreshSession()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                isRefreshing = false
            }
        } label: {
            Image(systemName: isRefreshing ? "arrow.trianglehead.2.clockwise.rotate.90" : "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(isRefreshing ? .degrees(360) : .zero)
                .animation(
                    isRefreshing ? .linear(duration: 0.7).repeatForever(autoreverses: false) : .default,
                    value: isRefreshing
                )
        }
        .buttonStyle(.plain)
        .help("立即重新抓取 Claude 與 Codex usage")
    }

    // MARK: - Usage bars

    /// Effective output-token quota (priority: manual > P95 detected > fallback 44K).
    private var planLimit: Int {
        if manualLimit   > 1_000 { return manualLimit }
        if detectedLimit > 1_000 { return detectedLimit }
        return 44_000
    }

    private var claudeBar: some View {
        usageBar(
            name: "Claude",
            window: "5h",
            progress: claudeProgress,
            percentLabel: claudeProgress.map { "\(Int($0 * 100))%" } ?? "—",
            trailing: claudeResetText
        )
    }

    @ViewBuilder
    private var codexBar: some View {
        switch model.codexUsageState {
        case .available(let info):
            usageBar(
                name: "Codex",
                window: info.windowText,
                progress: min(max(Double(info.usedPercent) / 100, 0), 1),
                percentLabel: "\(info.usedPercent)%",
                trailing: info.resetsAt.map { compactResetText(from: $0) }
            )
        case .unavailable, .error:
            usageBar(name: "Codex", window: "7d", progress: nil, percentLabel: "—", trailing: nil)
        }
    }

    /// Claude quota: prefer server-verified % (when fresh), else local session output ratio.
    private var claudeProgress: Double? {
        if let ci = model.claudeUsageInfo, !ci.isStale {
            return min(Double(ci.sessionPct) / 100.0, 1.0)
        }
        guard let u = model.sessionStatus else { return nil }
        if let out = u.sessionOutput {
            return min(Double(out) / Double(planLimit), 1.0)
        }
        return u.sessionTokenProgress(planLimit: planLimit)
    }

    private var claudeResetText: String? {
        if let ci = model.claudeUsageInfo, !ci.isStale, let r = ci.sessionReset {
            return ClaudeUsageInfo.resetsInText(from: r)
        }
        if let u = model.sessionStatus {
            let t = u.resetsInText
            return t == "—" ? nil : t
        }
        return nil
    }

    @ViewBuilder
    private func usageBar(name: String, window: String, progress: Double?, percentLabel: String, trailing: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(name).font(.caption.weight(.medium)).frame(width: 48, alignment: .leading)
                Text(window).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.2)).frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(progress: progress ?? 0))
                            .frame(width: geo.size.width * (progress ?? 0), height: 6)
                            .animation(.easeOut(duration: 0.4), value: progress ?? 0)
                    }
                }
                .frame(height: 6)
                Text(percentLabel)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(minWidth: 32, alignment: .trailing)
            }
        }
    }

    // MARK: - Style helpers

    private func barColor(progress: Double) -> Color {
        progress > 0.85 ? .red : progress > 0.65 ? .orange : Color(NSColor.controlAccentColor)
    }

    private func compactResetText(from reset: Date) -> String {
        let remainingSeconds = Int(reset.timeIntervalSinceNow)
        guard remainingSeconds > 0 else { return "Resetting…" }
        let days = remainingSeconds / 86_400
        guard days > 0 else { return ClaudeUsageInfo.resetsInText(from: reset) }
        let hours = (remainingSeconds % 86_400) / 3_600
        if hours > 0 { return "Resets in \(days)d \(hours)h" }
        let minutes = (remainingSeconds % 3_600) / 60
        return "Resets in \(days)d \(minutes)m"
    }
}
