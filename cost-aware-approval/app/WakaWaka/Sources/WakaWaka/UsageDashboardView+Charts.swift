import SwiftUI
import Charts

/// The daily-usage body: KPI tiles, the stacked chart, the per-agent breakdown and their formatting.
extension UsageDashboardView {
    // MARK: KPI row

    func kpiRow(_ data: DailyUsage) -> some View {
        let total = periodTotal(data)
        let today = data.days.last.map { dayTotal($0) } ?? 0
        let avg = data.days.isEmpty ? 0 : total / Double(data.days.count)
        return HStack(spacing: 12) {
            kpiTile(title: "今日", value: today)
            kpiTile(title: "\(data.days.count) 日總計", value: total)
            kpiTile(title: "日均", value: avg)
        }
    }

    func kpiTile(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(formatValue(value)).font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Chart

    func chart(_ data: DailyUsage) -> some View {
        Chart(chartRows(data)) { row in
            BarMark(
                x: .value("日期", shortDate(row.date)),
                y: .value(metric.axisLabel, row.value)
            )
            .foregroundStyle(by: .value("Agent", row.agent))
        }
        .chartForegroundStyleScale(range: chartColors(data))
        .frame(height: 240)
    }

    // MARK: Breakdown (per-agent share for the period)

    func breakdown(_ data: DailyUsage) -> some View {
        let totals = agentTotals(data)
        let sum = totals.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Agent 佔比（\(metric.rawValue)）").font(.subheadline.weight(.semibold))
            ForEach(UsageAgent.allCases) { agent in
                if let v = totals[agent] {
                    HStack {
                        Circle().fill(Self.agentColors[agent.rawValue] ?? .gray).frame(width: 8, height: 8)
                        Text(agent.rawValue)
                        Spacer()
                        Text(formatValue(v)).foregroundStyle(.secondary)
                        Text(sum > 0 ? String(format: "%.0f%%", v / sum * 100) : "—")
                            .frame(width: 46, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: - Derived data

    struct ChartRow: Identifiable {
        let id = UUID()
        let date: String
        let agent: String
        let value: Double
    }

    func chartRows(_ data: DailyUsage) -> [ChartRow] {
        var rows: [ChartRow] = []
        for day in data.days {
            for agent in UsageAgent.allCases {
                if let v = day.value(for: agent, metric: metric), v > 0 {
                    rows.append(ChartRow(date: day.date, agent: agent.rawValue, value: v))
                }
            }
        }
        return rows
    }

    /// Only include colors for agents that actually appear, so the legend/scale
    /// stays consistent with the bars drawn.
    func chartColors(_ data: DailyUsage) -> [Color] {
        presentAgents(data).map { Self.agentColors[$0.rawValue] ?? .gray }
    }

    func presentAgents(_ data: DailyUsage) -> [UsageAgent] {
        UsageAgent.allCases.filter { agent in
            data.days.contains { ($0.value(for: agent, metric: metric) ?? 0) > 0 }
        }
    }

    func agentTotals(_ data: DailyUsage) -> [UsageAgent: Double] {
        var totals: [UsageAgent: Double] = [:]
        for agent in UsageAgent.allCases {
            var sum = 0.0
            var seen = false
            for day in data.days {
                if let v = day.value(for: agent, metric: metric) {
                    sum += v
                    seen = true
                }
            }
            if seen { totals[agent] = sum }
        }
        return totals
    }

    func periodTotal(_ data: DailyUsage) -> Double {
        data.days.reduce(0) { $0 + dayTotal($1) }
    }

    func dayTotal(_ day: DayUsage) -> Double {
        UsageAgent.allCases.reduce(0) { $0 + (day.value(for: $1, metric: metric) ?? 0) }
    }

    func codexHasUsageButNoCost(_ data: DailyUsage) -> Bool {
        data.days.contains { $0.agents.codex != nil && $0.agents.codex?.costUSD == nil }
    }

    // MARK: - Formatting

    func formatValue(_ v: Double) -> String {
        metric == .cost ? formatUSD(v) : formatTokens(Int(v))
    }

    func formatUSD(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    func shortDate(_ iso: String) -> String {
        // "2026-07-23" → "07/23"
        let parts = iso.split(separator: "-")
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : iso
    }
}
