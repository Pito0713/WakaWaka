import SwiftUI

/// The expanded half of a queue row: diff sections, usage block and the risk banner.
extension QueueItemRow {
    @ViewBuilder
    var expandedSection: some View {
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
            } else if !item.canBeAllowed {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.slash.fill")
                        .foregroundStyle(.red)
                    Text("此操作已由政策拒絕")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onDeny) {
                        Label("Deny", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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
    func diffSectionView(_ section: DiffSection) -> some View {
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
    func usageBlock(_ u: UsageOutput) -> some View {
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

    func fmtK(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n)/1_000_000)
        : n >= 1_000   ? String(format: "%.1fK", Double(n)/1_000)
        : "\(n)"
    }

    func fmtCost(_ usd: Double) -> String {
        usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
    }

    // MARK: - Other helpers

    var denyBtn: some View {
        Button(action: onDeny) {
            Label("Deny", systemImage: "xmark.circle.fill")
        }
        .buttonStyle(.bordered)
        .foregroundStyle(.red)
    }

    @ViewBuilder
    func riskBanner(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    var riskColor: Color {
        switch risk {
        case .critical: return .red
        case .high:     return .orange
        case .medium:   return .secondary
        case .low:      return .green
        }
    }

    var riskLabel: String {
        switch risk {
        case .critical: return "CRITICAL"
        case .high:     return "HIGH"
        case .medium:   return "MEDIUM"
        case .low:      return "LOW"
        }
    }
}
