import SwiftUI
import Charts
import AppKit

// MARK: - Window controller

/// Standalone resizable window for the usage dashboard. Kept alive by AppDelegate
/// so closing it just hides the window (the app is a menu-bar accessory and never
/// quits on window close).
final class UsageDashboardWindowController: NSWindowController {
    private let service = DailyUsageService()
    private let phaseService = PhaseUsageService()

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
        window.contentViewController = NSHostingController(
            rootView: UsageDashboardView(service: service, phaseService: phaseService)
        )
    }

    /// Brings the window forward with a fresh live-quota snapshot and (re)loads
    /// the current window length.
    ///
    /// Only the daily tab is loaded here. The phase report reads message
    /// content rather than usage totals, so it is slower; it loads the first
    /// time its tab is actually opened.
    func present(liveQuota: LiveQuotaSnapshot?) {
        window?.contentViewController = NSHostingController(
            rootView: UsageDashboardView(service: service, phaseService: phaseService, liveQuota: liveQuota)
        )
        service.load(days: service.days)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root view

struct LiveQuotaSnapshot {
    let claudeUsage: UsageOutput?
    let claudeServer: ClaudeUsageInfo?
    let codex: CodexUsageState
}

/// Which report the window is showing. Only `daily` existed before; the phase
/// report is a second tab rather than more rows, because it answers a
/// different question and carries its own caveats.
enum DashboardTab: String, CaseIterable, Identifiable {
    case daily = "每日用量"
    case phase = "活動分佈"
    var id: String { rawValue }
}

struct UsageDashboardView: View {
    @ObservedObject var service: DailyUsageService
    @ObservedObject var phaseService: PhaseUsageService
    let liveQuota: LiveQuotaSnapshot?

    @AppStorage("manualPlanLimit") private var manualPlanLimit = 0
    @AppStorage(ClaudePlan.detectedLimitKey) private var detectedLimit = 0
    @State private var tab: DashboardTab = .daily
    @State private var daysSelection = 7
    @State private var metric: UsageMetric = .cost
    /// Defaults to output per plan §3 — it is the most direct reading of "what
    /// did this phase generate", with cost and call count alongside it.
    @State private var phaseMetric: PhaseMetric = .output
    @State private var isShowingCalibration = false
    @State private var calibrationInput = ""
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private static let agentColors: [String: Color] = [
        UsageAgent.claude.rawValue: .blue,
        UsageAgent.codex.rawValue:  .green,
    ]

    init(service: DailyUsageService, phaseService: PhaseUsageService, liveQuota: LiveQuotaSnapshot? = nil) {
        self.service = service
        self.phaseService = phaseService
        self.liveQuota = liveQuota
        // Mirror the service's current window so a rebuilt rootView (via present)
        // shows a picker that matches the data actually loaded, not a reset to 7.
        _daysSelection = State(initialValue: service.days)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 400)
        .onReceive(ticker) { now = $0 }
        .sheet(isPresented: $isShowingCalibration) {
            calibrationSheet
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(DashboardTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            // The phase report is slower, so it loads when its tab is first
            // opened rather than on every window present.
            .onChange(of: tab) { _, new in
                if new == .phase { phaseService.load(days: daysSelection) }
            }

            Spacer()

            Picker("", selection: $daysSelection) {
                Text("7 天").tag(7)
                Text("14 天").tag(14)
                Text("30 天").tag(30)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .onChange(of: daysSelection) { _, new in
                service.load(days: new)
                if tab == .phase || phaseService.hasLoaded { phaseService.load(days: new) }
            }

            metricPicker

            Button(action: refreshCurrentTab) {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新讀取")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Each tab has its own metric set — the daily chart plots cost or raw
    /// tokens, the phase report also offers call count.
    @ViewBuilder
    private var metricPicker: some View {
        switch tab {
        case .daily:
            Picker("", selection: $metric) {
                ForEach(UsageMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
        case .phase:
            Picker("", selection: $phaseMetric) {
                ForEach(PhaseMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
    }

    private func refreshCurrentTab() {
        switch tab {
        case .daily: service.load(days: service.days, force: true)
        case .phase: phaseService.load(days: daysSelection, force: true)
        }
    }

    // MARK: State routing

    private var content: some View {
        VStack(spacing: 0) {
            // Live quota is about "how much is left right now", which applies
            // whichever report is on screen, so it stays above the tabs.
            liveQuotaSection
                .padding(16)
            Divider()
            switch tab {
            case .daily:
                dailyUsageContent
            case .phase:
                PhaseUsageView(service: phaseService, metric: $phaseMetric)
            }
        }
    }

    @ViewBuilder
    private var dailyUsageContent: some View {
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

    // MARK: Live quota

    private var liveQuotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("即時額度").font(.subheadline.weight(.semibold))
                Spacer()
                Button("校正") {
                    calibrationInput = manualPlanLimit > 1_000 ? String(manualPlanLimit) : ""
                    isShowingCalibration = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let liveQuota {
                claudeQuotaRow(liveQuota)
                claudeWeeklyQuotaRow(liveQuota.claudeServer)
                codexQuotaRow(liveQuota.codex)
            } else {
                Text("尚無即時資料")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func claudeQuotaRow(_ snapshot: LiveQuotaSnapshot) -> some View {
        let progress = claudeProgress(snapshot)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Claude 5h").font(.callout.weight(.medium))
                if let server = snapshot.claudeServer {
                    freshnessIndicator(isStale: server.isStale)
                }
                Spacer()
                Text(claudeResetText(snapshot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .id(now)
            }
            quotaProgressBar(progress: progress, percentText: "\(Int(progress * 100))%")
            claudeBurnRate(snapshot.claudeUsage)
        }
    }

    /// Weekly (7-day) quota row. Only the server-side `/usage` snapshot reports the
    /// weekly percentage, so this renders only when that data is present.
    @ViewBuilder
    private func claudeWeeklyQuotaRow(_ server: ClaudeUsageInfo?) -> some View {
        if let server, let weeklyPct = server.weeklyPct {
            let progress = clampedProgress(Double(weeklyPct) / 100)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Claude Weekly").font(.callout.weight(.medium))
                    freshnessIndicator(isStale: server.isStale)
                    Spacer()
                    Text(server.weeklyReset.map(compactResetText) ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .id(now)
                }
                quotaProgressBar(progress: progress, percentText: "\(weeklyPct)%")
            }
        }
    }

    @ViewBuilder
    private func codexQuotaRow(_ state: CodexUsageState) -> some View {
        switch state {
        case .available(let info):
            codexWindowQuotaRow(info.primary, info: info)
            if let secondary = info.secondary {
                codexWindowQuotaRow(secondary, info: info)
            }
        case .unavailable:
            unavailableQuotaRow(label: "Codex account quota", message: "unavailable")
        case .error:
            unavailableQuotaRow(label: "Codex account quota", message: "error")
        }
    }

    private func codexWindowQuotaRow(_ usage: CodexWindowUsage, info: CodexUsageInfo) -> some View {
        let progress = clampedProgress(Double(usage.usedPercent) / 100)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Codex \(usage.windowText)\(info.isStale ? " · stale" : "")")
                    .font(.callout.weight(.medium))
                freshnessIndicator(
                    isStale: info.isStale,
                    helpText: "\(info.isStale ? "Stale local account snapshot" : "Local Codex account snapshot") · \(info.snapshotText())"
                )
                Spacer()
                Text(usage.resetText() ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .id(now)
            }
            quotaProgressBar(progress: progress, percentText: "\(usage.usedPercent)%")
        }
    }

    private func unavailableQuotaRow(label: String, message: String) -> some View {
        HStack {
            Text(label).font(.callout.weight(.medium))
            Spacer()
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func quotaProgressBar(progress: Double, percentText: String) -> some View {
        HStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(quotaBarColor(progress))
                        .frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 7)
            Text(percentText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func claudeBurnRate(_ usage: UsageOutput?) -> some View {
        if let usage,
           let start = usage.sessionStart,
           let reset = usage.sessionReset,
           let output = usage.sessionOutput {
            let elapsedHours = max(Date().timeIntervalSince(start) / 3_600, 0.001)
            if elapsedHours > 0.1 {
                let burnRate = Double(output) / elapsedHours
                let remainingHours = max(reset.timeIntervalSinceNow / 3_600, 0)
                let estimatedProgress = (Double(output) + burnRate * remainingHours) / Double(planLimit)
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.8))
                    Text("~\(formatTokens(Int(burnRate)))/h")
                    Text("·").foregroundStyle(.tertiary)
                    Text("預估滿 \(Int(min(estimatedProgress * 100, 999)))%")
                        .foregroundStyle(burnRateColor(estimatedProgress))
                        .id(now)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }

    private var calibrationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("校正 Claude 額度").font(.headline)
            Text("輸入方案在 5 小時滾動窗內的 output-token 上限。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("例如 44000", text: $calibrationInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                if manualPlanLimit > 1_000 {
                    Button("清除") {
                        manualPlanLimit = 0
                        isShowingCalibration = false
                    }
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("取消") { isShowingCalibration = false }
                Button("套用") {
                    guard let limit = parsedCalibrationLimit else { return }
                    manualPlanLimit = limit
                    isShowingCalibration = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsedCalibrationLimit == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var parsedCalibrationLimit: Int? {
        guard let limit = Int(calibrationInput), limit > 1_000 else { return nil }
        return limit
    }

    private var planLimit: Int {
        if manualPlanLimit > 1_000 { return manualPlanLimit }
        if detectedLimit > 1_000 { return detectedLimit }
        return 44_000
    }

    private func claudeProgress(_ snapshot: LiveQuotaSnapshot) -> Double {
        if let server = snapshot.claudeServer, !server.isStale {
            return clampedProgress(Double(server.sessionPct) / 100)
        }
        guard let usage = snapshot.claudeUsage else { return 0 }
        return clampedProgress(usage.sessionTokenProgress(planLimit: planLimit))
    }

    private func claudeResetText(_ snapshot: LiveQuotaSnapshot) -> String {
        if let server = snapshot.claudeServer,
           !server.isStale,
           let reset = server.sessionReset {
            return compactResetText(reset)
        }
        return snapshot.claudeUsage?.resetsInText ?? "—"
    }

    private func compactResetText(_ reset: Date) -> String {
        let remainingSeconds = Int(reset.timeIntervalSinceNow)
        guard remainingSeconds > 0 else { return "Resetting…" }
        let days = remainingSeconds / 86_400
        if days == 0 { return ClaudeUsageInfo.resetsInText(from: reset) }
        let hours = (remainingSeconds % 86_400) / 3_600
        return hours > 0 ? "Resets in \(days)d \(hours)h" : "Resets in \(days)d"
    }

    private func freshnessIndicator(isStale: Bool, helpText: String? = nil) -> some View {
        Circle()
            .fill(isStale ? Color.orange : Color.green.opacity(0.85))
            .frame(width: 6, height: 6)
            .help(helpText ?? (isStale ? "資料已過期" : "資料為最新"))
    }

    private func quotaBarColor(_ progress: Double) -> Color {
        progress > 0.85 ? .red : progress > 0.65 ? .orange : Color(nsColor: .controlAccentColor)
    }

    private func burnRateColor(_ progress: Double) -> Color {
        progress > 0.95 ? .red : progress > 0.80 ? .orange : .secondary
    }

    private func clampedProgress(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
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
