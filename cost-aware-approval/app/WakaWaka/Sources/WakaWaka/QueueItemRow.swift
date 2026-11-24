import SwiftUI

// MARK: - Queue row

struct QueueItemRow: View {
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

    @AppStorage(ClaudePlan.detectedLimitKey) var detectedLimit: Int = 0
    @AppStorage("manualPlanLimit")           private var manualLimit:   Int = 0

    @State var isRowHovered = false
    @State var isDetailExpanded = false

    // ── Per-item countdown ────────────────────────────────────────────────────
    /// Must match FINAL_TIMEOUT_MS in pretooluse.mjs (9m50s = 590s)
    static let hookTimeoutSeconds: Double = 590

    let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State var now: Date = Date()

    static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Deadline = timestamp the hook wrote the pending file + 8 minutes
    var deadline: Date? {
        guard let ts = item.timestamp, !item.isExpired else { return nil }
        let d = Self.isoParser.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
        return d?.addingTimeInterval(Self.hookTimeoutSeconds)
    }

    /// "7:32" / "0:09" — nil when expired or no timestamp
    var countdownText: String? {
        guard let d = deadline else { return nil }
        let rem = d.timeIntervalSince(now)
        guard rem > 0 else { return nil }
        let total = Int(rem)
        let m = total / 60
        let s = total % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    var countdownColor: Color {
        if item.hookUrgent == true { return .red }   // urgent mode: always red
        guard let d = deadline else { return .secondary }
        let rem = d.timeIntervalSince(now)
        if rem <= 30  { return .red }
        if rem <= 120 { return .orange }
        return .secondary
    }

    var planLimit: Int {
        if manualLimit   > 1_000 { return manualLimit }
        if detectedLimit > 1_000 { return detectedLimit }
        return 44_000
    }

    var risk:    RiskLevel { item.risk_level ?? .medium }
    var isBash:  Bool      {
        item.tool_name == "Bash" || item.tool_name == "run_command" || item.tool_name == "run_shell_command"
    }
    var canAlwaysAllow: Bool { isBash && risk == .medium }

    /// Label and color for the agent badge — every pending item shows one.
    var agentInfo: (label: String, color: Color) {
        switch item.agent {
        case "agy":
            return (item.agentDisplayLabel, Color(red: 0.45, green: 0.25, blue: 0.95))
        case "codex":
            return (item.agentDisplayLabel, Color(red: 0.10, green: 0.55, blue: 0.45))
        case "claude-code", .none:
            // nil means Claude Code (pre-multi-agent pending files)
            return (item.agentDisplayLabel, Color(red: 0.87, green: 0.38, blue: 0.18))
        default:
            return (item.agentDisplayLabel, .secondary)
        }
    }

    @ViewBuilder
    func agyQuotaSecondaryView(_ quota: AgyQuota) -> some View {
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

}
