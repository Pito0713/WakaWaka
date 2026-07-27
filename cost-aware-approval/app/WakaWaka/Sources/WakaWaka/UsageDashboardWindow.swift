import SwiftUI
import Charts
import AppKit

// MARK: - Window controller

/// Standalone resizable window for the usage dashboard. Kept alive by AppDelegate
/// so closing it just hides the window (the app is a menu-bar accessory and never
/// quits on window close).
final class UsageDashboardWindowController: NSWindowController {
    private let service = DailyUsageService()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "用量儀表板"
        window.isReleasedWhenClosed = false          // controller outlives a close
        window.setFrameAutosaveName("UsageDashboardWindow")   // remember size/position
        window.center()
        self.init(window: window)
        window.contentViewController = NSHostingController(rootView: UsageDashboardView(service: service))
    }

    /// Brings the window forward and (re)loads the current window length.
    func present() {
        service.load(days: service.days)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root view

struct UsageDashboardView: View {
    @ObservedObject var service: DailyUsageService
    @State private var daysSelection = 7
    @State private var metric: UsageMetric = .cost

    private static let agentColors: [String: Color] = [
        UsageAgent.claude.rawValue: .blue,
        UsageAgent.codex.rawValue:  .green,
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("用量儀表板").font(.headline)
            Spacer()
            Picker("", selection: $daysSelection) {
                Text("7 天").tag(7)
                Text("14 天").tag(14)
                Text("30 天").tag(30)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .onChange(of: daysSelection) { _, new in service.load(days: new) }

            Picker("", selection: $metric) {
                ForEach(UsageMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 130)

            Button {
                service.load(days: service.days, force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新讀取")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: State routing

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .loading:
            ProgressView("讀取中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            statusMessage(icon: "exclamationmark.triangle", text: message)
        case .loaded(let data):
            if data.isEmpty {
                statusMessage(icon: "tray", text: "此期間沒有用量資料")
            } else {
                loaded(data)
            }
        }
    }

    private func statusMessage(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loaded

    private func loaded(_ data: DailyUsage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                kpiRow(data)
                chart(data)
                Divider()
                breakdown(data)
                if metric == .cost && codexHasUsageButNoCost(data) {
                    Label("Codex 成本未估算：pricing.json 尚未填入 Codex 價格", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if metric == .cost {
                    Text("成本為估算值，非實際帳單").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(16)
        }
    }

    // MARK: KPI row

    private func kpiRow(_ data: DailyUsage) -> some View {
        let total = periodTotal(data)
        let today = data.days.last.map { dayTotal($0) } ?? 0
        let avg = data.days.isEmpty ? 0 : total / Double(data.days.count)
        return HStack(spacing: 12) {
            kpiTile(title: "今日", value: today)
            kpiTile(title: "\(data.days.count) 日總計", value: total)
            kpiTile(title: "日均", value: avg)
        }
    }

    private func kpiTile(title: String, value: Double) -> some View {
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

    private func chart(_ data: DailyUsage) -> some View {
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

    private func breakdown(_ data: DailyUsage) -> some View {
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

    private struct ChartRow: Identifiable {
        let id = UUID()
        let date: String
        let agent: String
        let value: Double
    }

    private func chartRows(_ data: DailyUsage) -> [ChartRow] {
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
    private func chartColors(_ data: DailyUsage) -> [Color] {
        presentAgents(data).map { Self.agentColors[$0.rawValue] ?? .gray }
    }

    private func presentAgents(_ data: DailyUsage) -> [UsageAgent] {
        UsageAgent.allCases.filter { agent in
            data.days.contains { ($0.value(for: agent, metric: metric) ?? 0) > 0 }
        }
    }

    private func agentTotals(_ data: DailyUsage) -> [UsageAgent: Double] {
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

    private func periodTotal(_ data: DailyUsage) -> Double {
        data.days.reduce(0) { $0 + dayTotal($1) }
    }

    private func dayTotal(_ day: DayUsage) -> Double {
        UsageAgent.allCases.reduce(0) { $0 + (day.value(for: $1, metric: metric) ?? 0) }
    }

    private func codexHasUsageButNoCost(_ data: DailyUsage) -> Bool {
        data.days.contains { $0.agents.codex != nil && $0.agents.codex?.costUSD == nil }
    }

    // MARK: - Formatting

    private func formatValue(_ v: Double) -> String {
        metric == .cost ? formatUSD(v) : formatTokens(Int(v))
    }

    private func formatUSD(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func shortDate(_ iso: String) -> String {
        // "2026-07-23" → "07/23"
        let parts = iso.split(separator: "-")
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : iso
    }
}
