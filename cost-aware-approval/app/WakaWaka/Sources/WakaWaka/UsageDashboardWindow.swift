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

    @AppStorage("manualPlanLimit") var manualPlanLimit = 0
    @AppStorage(ClaudePlan.detectedLimitKey) var detectedLimit = 0
    @State var tab: DashboardTab = .daily
    @State var daysSelection = 7
    @State var metric: UsageMetric = .cost
    /// Defaults to output per plan §3 — it is the most direct reading of "what
    /// did this phase generate", with cost and call count alongside it.
    @State var phaseMetric: PhaseMetric = .output
    @State var isShowingCalibration = false
    @State var calibrationInput = ""
    @State var now = Date()
    let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    static let agentColors: [String: Color] = [
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

    var header: some View {
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
    var metricPicker: some View {
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

    func refreshCurrentTab() {
        switch tab {
        case .daily: service.load(days: service.days, force: true)
        case .phase: phaseService.load(days: daysSelection, force: true)
        }
    }

    // MARK: State routing

    var content: some View {
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
    var dailyUsageContent: some View {
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

    func statusMessage(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loaded

    func loaded(_ data: DailyUsage) -> some View {
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

}
