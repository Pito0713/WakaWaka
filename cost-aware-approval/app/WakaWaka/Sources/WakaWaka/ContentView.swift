import SwiftUI

// MARK: - Root view

struct ContentView: View {
    @ObservedObject var model: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.pendingItems.isEmpty {
                idleView
            } else {
                // ── Header ──────────────────────────────────────────────
                HStack {
                    Text("待審批")
                        .font(.subheadline.weight(.semibold))
                    Text("\(model.pendingItems.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                // ── Queue list ───────────────────────────────────────────
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.pendingItems.indices, id: \.self) { idx in
                            QueueItemRow(
                                item:      model.pendingItems[idx],
                                index:     idx,
                                isExpanded: model.expandedIndex == idx,
                                usage:     model.expandedIndex == idx ? model.usage : nil,
                                isLoading: model.expandedIndex == idx ? model.isLoadingUsage : false,
                                agyQuota:  model.pendingItems[idx].agent == "agy" ? model.agyQuota : nil,
                                onToggle:  { model.onToggleExpand(idx) },
                                onAllow:   { model.onAllow(idx) },
                                onAlwaysAllow: { model.onAlwaysAllow(idx) },
                                onDeny:    { model.onDeny(idx) },
                                onDismiss: { model.onDismiss(idx) }
                            )
                            if idx < model.pendingItems.count - 1 {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                }
            }

            // ── Always-visible per-agent auto-mode toggles ─────────────────
            AutoModeBar(
                claudeCodeState: model.claudeCodeAutoMode,
                agyState: model.agyAutoMode,
                onToggle: { agent, enabled in model.onToggleAutoMode(agent, enabled) }
            )

            // ── Always-visible session status ────────────────────────────
            SessionStatusView(
                usage: model.sessionStatus,
                isLoading: model.isLoadingSession,
                claudeUsage: model.claudeUsageInfo,
                onRefresh: { model.onRefreshSession() }
            )
        }
        .frame(width: 480)
        // Opaque, appearance-adaptive background so the popover never flashes a bare
        // white frame before SwiftUI paints its content.
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.2), value: model.pendingItems.count)
        .animation(.easeOut(duration: 0.2), value: model.expandedIndex)
    }

    private var idleView: some View {
        VStack(spacing: 10) {
            PacManIdleView()
            Text("No pending approval").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Queue row

private struct QueueItemRow: View {
    let item:      PendingData
    let index:     Int
    let isExpanded: Bool
    let usage:     UsageOutput?
    let isLoading: Bool
    let agyQuota:  AgyQuota?
    let onToggle:  () -> Void
    let onAllow:   () -> Void
    let onAlwaysAllow: () -> Void
    let onDeny:    () -> Void
    let onDismiss: () -> Void

    @AppStorage(ClaudePlan.detectedLimitKey) private var detectedLimit: Int = 0
    @AppStorage("manualPlanLimit")           private var manualLimit:   Int = 0

    @State private var isRowHovered = false
    @State private var isDetailExpanded = false

    // ── Per-item countdown ────────────────────────────────────────────────────
    /// Must match FINAL_TIMEOUT_MS in pretooluse.mjs (9m50s = 590s)
    private static let hookTimeoutSeconds: Double = 590

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now: Date = Date()

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Deadline = timestamp the hook wrote the pending file + 8 minutes
    private var deadline: Date? {
        guard let ts = item.timestamp, !item.isExpired else { return nil }
        let d = Self.isoParser.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
        return d?.addingTimeInterval(Self.hookTimeoutSeconds)
    }

    /// "7:32" / "0:09" — nil when expired or no timestamp
    private var countdownText: String? {
        guard let d = deadline else { return nil }
        let rem = d.timeIntervalSince(now)
        guard rem > 0 else { return nil }
        let total = Int(rem)
        let m = total / 60
        let s = total % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    private var countdownColor: Color {
        if item.hookUrgent == true { return .red }   // urgent mode: always red
        guard let d = deadline else { return .secondary }
        let rem = d.timeIntervalSince(now)
        if rem <= 30  { return .red }
        if rem <= 120 { return .orange }
        return .secondary
    }

    private var planLimit: Int {
        if manualLimit   > 1_000 { return manualLimit }
        if detectedLimit > 1_000 { return detectedLimit }
        return 44_000
    }

    private var risk:    RiskLevel { item.risk_level ?? .medium }
    private var isBash:  Bool      {
        item.tool_name == "Bash" || item.tool_name == "run_command" || item.tool_name == "run_shell_command"
    }
    private var canAlwaysAllow: Bool { isBash && risk == .medium }

    /// Label and color for the agent badge — every pending item shows one.
    private var agentInfo: (label: String, color: Color) {
        switch item.agent {
        case "agy":
            return ("agy", Color(red: 0.45, green: 0.25, blue: 0.95))
        case "claude-code", .none:
            // nil means Claude Code (pre-multi-agent pending files)
            return ("Claude", Color(red: 0.87, green: 0.38, blue: 0.18))
        default:
            return (item.agent ?? "?", .secondary)
        }
    }

    @ViewBuilder
    private func agyQuotaSecondaryView(_ quota: AgyQuota) -> some View {
        let agentColor = Color(red: 0.45, green: 0.25, blue: 0.95)
        let barColor: Color = quota.remainingFraction < 0.15 ? .red
                            : quota.remainingFraction < 0.30 ? .orange
                            : agentColor.opacity(0.75)
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 60, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: max(2, 60 * quota.remainingFraction), height: 4)
                    .animation(.easeOut(duration: 0.4), value: quota.remainingFraction)
            }
            .frame(width: 60, height: 4)

            Text("\(Int(quota.remainingFraction * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(quota.countdownText(from: now))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .id(now)
        }
        .padding(.top, 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Collapsed header (always visible) ───────────────────────
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    // Expand/collapse chevron
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isRowHovered && !isExpanded ? Color.primary.opacity(0.6) : .secondary)
                        .frame(width: 14)
                        .animation(.easeInOut(duration: 0.12), value: isRowHovered)

                    // Risk dot
                    Circle()
                        .fill(riskColor.opacity(0.85))
                        .frame(width: 8, height: 8)

                    // Tool + summary + quota bar (agy only)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(item.tool_name ?? "Tool")
                                .font(.subheadline.weight(.medium))
                            let agent = agentInfo
                            Text(agent.label)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(agent.color.opacity(0.14))
                                .foregroundStyle(agent.color)
                                .clipShape(Capsule())
                        }
                        if !item.toolInputSummary.isEmpty {
                            Text(item.toolInputSummary)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(isRowHovered && !isExpanded ? 3 : 1)
                                .animation(.easeInOut(duration: 0.15), value: isRowHovered)
                        }
                        if let q = agyQuota, !q.isStale {
                            agyQuotaSecondaryView(q)
                        }
                    }

                    Spacer()

                    // Per-item countdown (only when hook is still waiting)
                    if let ct = countdownText {
                        HStack(spacing: 2) {
                            Image(systemName: "timer")
                                .font(.caption2)
                                .foregroundStyle(countdownColor)
                            Text(ct)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(countdownColor)
                        }
                        .id(now)
                    }

                    // Risk badge (or expired badge)
                    if item.isExpired {
                        Text("已逾時")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    } else {
                        Text(riskLabel)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(riskColor.opacity(0.15))
                            .foregroundStyle(riskColor)
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isRowHovered && !isExpanded
                        ? Color.secondary.opacity(0.06)
                        : Color.clear
                )
                .animation(.easeInOut(duration: 0.12), value: isRowHovered)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isRowHovered = $0 }
            .onReceive(ticker) { t in now = t }

            // ── Expanded detail ─────────────────────────────────────────
            if isExpanded {
                expandedSection
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal:   .opacity
                    ))
            }
        }
    }

    @ViewBuilder
    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Risk banner
            if risk == .critical {
                riskBanner(icon: "exclamationmark.octagon.fill", color: .red,
                           text: "極高風險 — 此操作可能造成不可逆損害，請確認後再允許")
            } else if risk == .high {
                riskBanner(icon: "exclamationmark.triangle.fill", color: .orange,
                           text: "高風險操作 — 請確認後再允許")
            }

            // Urgent banner: hook at 8-min warn threshold, auto-deny coming soon
            if item.hookUrgent == true, let ct = countdownText {
                riskBanner(icon: "timer.badge.exclamationmark", color: .red,
                           text: "審批即將到期（剩 \(ct)）— 未審批將自動拒絕")
                    .id(now)
            }

            // Full detail scroll area (colored diff blocks)
            if !item.toolInputSections.isEmpty {
                let sections = isDetailExpanded ? item.toolInputSectionsFull : item.toolInputSections
                let hasTruncation = item.toolInputSections != item.toolInputSectionsFull

                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(sections) { section in
                                diffSectionView(section)
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: isDetailExpanded ? 520 : 220)
                    .animation(.easeInOut(duration: 0.22), value: isDetailExpanded)

                    // Show more / collapse toggle (only when content is truncated)
                    if hasTruncation {
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                isDetailExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isDetailExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                Text(isDetailExpanded ? "收合" : "展開全文")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.06))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }

            // Usage
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Calculating usage…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let u = usage {
                usageBlock(u)
            }

            Divider()

            // Buttons
            if item.isExpired {
                // Hook already gone — tool was NOT executed. User can only dismiss.
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.xmark")
                        .foregroundStyle(.secondary)
                    Text("此操作已逾時，工具未執行")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onDismiss) {
                        Label("Dismiss", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                }
            } else if canAlwaysAllow {
                HStack(spacing: 8) {
                    denyBtn
                    Spacer()
                    Button(action: onAlwaysAllow) {
                        Label("Always Allow", systemImage: "checkmark.seal.fill")
                    }.buttonStyle(.bordered)
                    Button("Allow Once", action: onAllow).buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 12) {
                    denyBtn
                    Spacer()
                    Button(action: onAllow) {
                        Label("Allow", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(risk == .critical ? .red : risk == .high ? .orange : .accentColor)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Diff section rendering

    @ViewBuilder
    private func diffSectionView(_ section: DiffSection) -> some View {
        switch section.kind {
        case .header:
            Text(section.text)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.top, 4)
        case .removed:
            Text(section.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.red.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Color.red.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .added:
            Text(section.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.green.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Color.green.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .plain:
            Text(section.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 6).padding(.vertical, 4)
        }
    }

    // MARK: - Usage block (redesigned)

    @ViewBuilder
    private func usageBlock(_ u: UsageOutput) -> some View {
        if let tOut = u.turnOutput, let tCost = u.turnCostUSD {
            HStack(spacing: 4) {
                Text("此任務").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Text("\(fmtK(tOut)) out")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.65))
                if let tCache = u.turnCacheRead, tCache > 0 {
                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                    Text("\(fmtK(tCache)) cache")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(fmtCost(tCost))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.primary.opacity(0.75))
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Usage helpers

    private func fmtK(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n)/1_000_000)
        : n >= 1_000   ? String(format: "%.1fK", Double(n)/1_000)
        : "\(n)"
    }

    private func fmtCost(_ usd: Double) -> String {
        usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
    }

    // MARK: - Other helpers

    private var denyBtn: some View {
        Button(action: onDeny) {
            Label("Deny", systemImage: "xmark.circle.fill")
        }
        .buttonStyle(.bordered)
        .foregroundStyle(.red)
    }

    @ViewBuilder
    private func riskBanner(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var riskColor: Color {
        switch risk {
        case .critical: return .red
        case .high:     return .orange
        case .medium:   return .secondary
        case .low:      return .green
        }
    }

    private var riskLabel: String {
        switch risk {
        case .critical: return "CRITICAL"
        case .high:     return "HIGH"
        case .medium:   return "MEDIUM"
        case .low:      return "LOW"
        }
    }
}

// MARK: - Auto-mode bar (per-agent 30-min auto-approve toggle)

/// Always-visible row of per-agent auto-mode toggles. Flipping a toggle writes
/// ~/.wakawaka/settings.json (via AppDelegate → SettingsService) for the
/// PreToolUse hook to read; this view only renders whatever state it's given.
private struct AutoModeBar: View {
    let claudeCodeState: AgentAutoMode
    let agyState: AgentAutoMode
    let onToggle: (AutoModeAgent, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 16) {
                    Text("Auto 模式")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    agentToggle(label: "Claude", agent: .claudeCode, state: claudeCodeState, now: context.date)
                    agentToggle(label: "agy",    agent: .agy,        state: agyState,        now: context.date)
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func agentToggle(label: String, agent: AutoModeAgent, state: AgentAutoMode, now: Date) -> some View {
        HStack(spacing: 5) {
            Toggle(isOn: Binding(
                get: { state.enabled },
                set: { onToggle(agent, $0) }
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

    /// "Auto ↻ 27m" while the window is live; nil once disabled or expired
    /// (expiry itself is reconciled by AppDelegate's 30s sweep, not here).
    private func remainingText(state: AgentAutoMode, now: Date) -> String? {
        guard state.enabled, let expiresAtStr = state.expiresAt,
              let expiry = SettingsService.parseExpiry(expiresAtStr)
        else { return nil }
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let minutes = Int(remaining) / 60
        return "Auto ↻ \(minutes)m"
    }
}

// MARK: - Ghost idle animation (mirrors menu bar icon, same pixel size)

/// Idle-state animation: Pac-Man chomps rightward along a pellet trail with a
/// ghost chasing behind. Eating the flashing power pellet flips the ghost to a
/// blue "frightened" face that falls back (flees). Everything is a pure function
/// of `frame` so the loop stays deterministic; motion is frozen when the system
/// "Reduce Motion" accessibility setting is on.
private struct PacManIdleView: View {
    @State private var frame = 0
    private let timer = Timer.publish(every: 0.14, on: .main, in: .common).autoconnect()

    // ── Pixel maps (1 = body, 0 = empty, 2 = cut-out that shows the background) ──
    private static let pacClosed: [[Int]] = [
        [0,0,1,1,1,1,1,0,0],
        [0,1,1,1,1,1,1,1,0],
        [1,1,1,1,1,1,1,1,1],
        [1,1,1,1,1,1,1,1,1],
        [1,1,1,1,1,1,1,1,1],
        [1,1,1,1,1,1,1,1,1],
        [1,1,1,1,1,1,1,1,1],
        [0,1,1,1,1,1,1,1,0],
        [0,0,1,1,1,1,1,0,0],
    ]
    private static let pacOpen: [[Int]] = [   // wedge mouth, facing right
        [0,0,1,1,1,1,1,0,0],
        [0,1,1,1,1,1,1,1,0],
        [1,1,1,1,1,1,0,0,0],
        [1,1,1,1,1,0,0,0,0],
        [1,1,1,1,0,0,0,0,0],
        [1,1,1,1,1,0,0,0,0],
        [1,1,1,1,1,1,0,0,0],
        [0,1,1,1,1,1,1,1,0],
        [0,0,1,1,1,1,1,0,0],
    ]
    private static let ghostEyes: [[Int]] = [   // eaten ghost — just the eyes, retreating
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
        [0,1,1,0,0,0,1,1,0],
        [0,1,1,0,0,0,1,1,0],
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
    ]
    // Ghost — two bottom-wave frames; face swapped for the frightened variant.
    private static func ghost(wave: Int, frightened: Bool) -> [[Int]] {
        var g: [[Int]] = [
            [0,0,1,1,1,1,1,0,0],
            [0,1,1,1,1,1,1,1,0],
            [1,1,1,1,1,1,1,1,1],
            [1,2,2,1,1,1,2,2,1],
            [1,2,2,1,1,1,2,2,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,0,1,1,0,1,1,0],
            [1,0,0,1,0,0,1,0,0],
        ]
        if wave == 1 {
            g[8] = [1,0,1,1,0,1,1,0,1]
            g[9] = [0,0,1,0,0,1,0,0,1]
        }
        if frightened {   // small dot eyes + zig-zag mouth
            g[3] = [1,1,2,1,1,1,2,1,1]
            g[4] = [1,1,2,1,1,1,2,1,1]
            g[6] = [1,2,1,2,1,2,1,2,1]
            g[7] = [1,1,2,1,2,1,2,1,1]
        }
        return g
    }

    // ── Scene geometry (measured in pixel cells; multiplied by `px`) ──
    private static let px: CGFloat        = 2.0   // integer → crisp at 1x and 2x
    private static let canvasCols: CGFloat = 80
    private static let pelletCols: [CGFloat] = [14, 24, 34, 44, 54, 64]
    private static let powerIndex          = 3          // pelletCols[3] is the power pellet
    private static let ghostGap: CGFloat   = 14         // cells Pac leads the ghost by
    private static let pacSpeed: CGFloat   = 1.8        // cells advanced per frame
    private static let pacStart: CGFloat   = -12        // enters from off-screen left
    // Loop length: travel until Pac exits the right edge, then restart.
    private static var loopFrames: Int {
        Int(((canvasCols + 12) - pacStart) / pacSpeed)  // ≈ 57
    }

    var body: some View {
        let px = Self.px
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Freeze on a legible mid-chomp pose when Reduce Motion is on.
        let L = Self.loopFrames
        let f = reduceMotion ? 20 : (frame % L)
        // Every 4th loop is the "hunt" easter egg: the ghost runs ahead in blue and
        // Pac chases it down (→ floating eyes) instead of the usual flee-behind.
        // Deterministic per loop so it stays a rare, repeatable surprise.
        let isHunt = !reduceMotion && (frame / L) % 4 == 3

        let pacX       = Self.pacStart + Self.pacSpeed * CGFloat(f)   // sprite left edge
        let pacCenter  = pacX + 4.5
        let powerCol   = Self.pelletCols[Self.powerIndex]
        // Power window: from eating the power pellet until it wears off.
        let powerWindow: CGFloat = 28
        let powerActive = pacCenter >= powerCol && pacCenter < powerCol + powerWindow
        // Frightened ghost falls back, then smoothly catches back up to the normal
        // chase gap — a triangular profile so `flee` returns to 0 continuously at the
        // window's end instead of snapping the ghost forward.
        let flee: CGFloat = {
            guard powerActive else { return 0 }
            let d = pacCenter - powerCol            // 0 … powerWindow
            let peak: CGFloat = 10                  // furthest-behind point
            let maxFlee: CGFloat = 12
            return d < peak
                ? maxFlee * (d / peak)                                   // falling back
                : maxFlee * max(0, (powerWindow - d) / (powerWindow - peak)) // catching up
        }()
        let ghostBehindX = pacX - Self.ghostGap - flee

        // Hunt-loop geometry: ghost leads, Pac closes the gap; once caught the ghost
        // becomes eyes that outrun Pac to the right and exit.
        let catchCenter: CGFloat = 50
        let ghostAheadX = pacX + max(5, (catchCenter - pacCenter) * 0.4 + 5)
        let eyesX       = (catchCenter - 4.5) + 5 + 4 * (pacCenter - catchCenter)
        let ghostCaught = pacCenter >= catchCenter

        let canvasW = Self.canvasCols * px
        let canvasH = 11 * px

        Canvas { ctx, _ in
            let isDark = NSApp.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bodyColor: Color = isDark ? .white : .black
            let pacColor:  Color = isDark ? Color(red: 1.0,  green: 0.85, blue: 0.20)
                                          : Color(red: 0.82, green: 0.60, blue: 0.0)
            let scaredColor: Color = isDark ? Color(red: 0.45, green: 0.62, blue: 1.0)
                                            : Color(red: 0.15, green: 0.35, blue: 0.9)

            func draw(_ map: [[Int]], atCol ox: CGFloat, rowOffset oy: CGFloat, color: Color) {
                for r in map.indices {
                    for c in map[r].indices where map[r][c] == 1 {
                        let rect = CGRect(
                            x: (ox + CGFloat(c)) * px,
                            y: (oy + CGFloat(r)) * px,
                            width: px, height: px
                        )
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }
            }

            // Pellets — small dots, eaten once Pac's centre passes them.
            let pelletCenterY = 5.0 * px
            for (i, col) in Self.pelletCols.enumerated() {
                guard pacCenter < col else { continue }        // already eaten
                if i == Self.powerIndex {
                    let d = px * 3.2                            // power pellet: bigger, flashing
                    let alpha: CGFloat = (f % 2 == 0) ? 1.0 : 0.3
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: col * px - d/2, y: pelletCenterY - d/2,
                                               width: d, height: d)),
                        with: .color(pacColor.opacity(alpha)))
                } else {
                    let d = px * 1.7
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: col * px - d/2, y: pelletCenterY - d/2,
                                               width: d, height: d)),
                        with: .color(bodyColor.opacity(0.5)))
                }
            }

            // Ghost. Normal loop: chases behind, turning blue while Pac is powered.
            // Hunt loop: flees ahead in blue, then is eaten → floating eyes retreat.
            let wave = f % 2
            if isHunt {
                if ghostCaught {
                    draw(Self.ghostEyes, atCol: eyesX, rowOffset: 0.5, color: bodyColor)
                } else {
                    draw(Self.ghost(wave: wave, frightened: true),
                         atCol: ghostAheadX, rowOffset: 0.5, color: scaredColor)
                }
            } else {
                draw(Self.ghost(wave: wave, frightened: powerActive),
                     atCol: ghostBehindX, rowOffset: 0.5,
                     color: powerActive ? scaredColor : bodyColor)
            }

            // Pac-Man — chomps open/closed, always facing right.
            let pacMap = (f % 2 == 0) ? Self.pacOpen : Self.pacClosed
            draw(pacMap, atCol: pacX, rowOffset: 1.0, color: pacColor)
        }
        .frame(width: canvasW, height: canvasH)
        .onReceive(timer) { _ in
            guard !reduceMotion else { return }
            frame &+= 1
        }
    }
}
