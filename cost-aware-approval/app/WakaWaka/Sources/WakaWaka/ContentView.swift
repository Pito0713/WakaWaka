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

            // ── Always-visible session status ────────────────────────────
            SessionStatusView(
                usage: model.sessionStatus,
                isLoading: model.isLoadingSession,
                claudeUsage: model.claudeUsageInfo,
                onRefresh: { model.onRefreshSession() }
            )
        }
        .frame(width: 480)
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

                    // Tool + summary
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

// MARK: - Ghost idle animation (mirrors menu bar icon, same pixel size)

private struct PacManIdleView: View {
    @State private var frame = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    // Same pixel art as AppDelegate.ghostFrames
    private static let ghostFrames: [[[Int]]] = [
        [   // Frame 0 — wave A
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
        ],
        [   // Frame 1 — wave B
            [0,0,1,1,1,1,1,0,0],
            [0,1,1,1,1,1,1,1,0],
            [1,1,1,1,1,1,1,1,1],
            [1,2,2,1,1,1,2,2,1],
            [1,2,2,1,1,1,2,2,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,0,1,1,0,1,1,0,1],
            [0,0,1,0,0,1,0,0,1],
        ],
    ]

    var body: some View {
        let px: CGFloat  = 1.87        // 1.7 × 1.1 = 10% larger than menu bar ghost
        let pixels       = Self.ghostFrames[frame % 2]
        let cols         = pixels[0].count   // 9
        let rows         = pixels.count      // 10
        let ghostW       = CGFloat(cols) * px
        let ghostH       = CGFloat(rows) * px

        // Pellet count: every 4 frames eat one, then respawn after all eaten
        let totalCycle   = 12                        // 3 pellets × 4 frames
        let pellets      = 3 - ((frame % totalCycle) / 4)   // 3 → 2 → 1 → (reset)
        let pelletSize   = px * 0.85
        let pelletGap    = px * 2.5
        let pelletStartX = ghostW + px * 2
        let canvasW      = pelletStartX + CGFloat(3) * pelletGap
        let pelletY      = ghostH / 2 - pelletSize / 2

        Canvas { ctx, size in
            let isDark = NSApp.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bodyColor: Color = isDark ? .white : .black

            // Ghost
            for row in 0..<rows {
                for col in 0..<cols {
                    guard pixels[row][col] == 1 else { continue }
                    let rect = CGRect(
                        x: CGFloat(col) * px,
                        y: CGFloat(row) * px,
                        width: px, height: px
                    )
                    ctx.fill(Path(rect), with: .color(bodyColor))
                }
            }

            // Square pellets — disappear one by one (left to right)
            for i in 0..<pellets {
                let pelletX = pelletStartX + CGFloat(i) * pelletGap
                ctx.fill(
                    Path(CGRect(x: pelletX, y: pelletY, width: pelletSize, height: pelletSize)),
                    with: .color(bodyColor.opacity(0.55))
                )
            }
        }
        .frame(width: canvasW, height: ghostH)
        .onReceive(timer) { _ in frame += 1 }
    }
}
