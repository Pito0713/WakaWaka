import SwiftUI

/// Always-visible session usage bar at the bottom of the popover.
/// Plan mode is always "Auto" — P95 detection + optional manual calibration.
///
///   Row 1  — "近5h 用量"  +  limit badge  +  calibrate btn  +  "Resets in Xh Ym"
///   Row 2  — token-based quota progress bar  +  % label
///   Row 3  — session output / limit  +  all-time cost
///   Row 4  — burn rate (tokens/h)  +  estimated % at reset  [elapsed > 6 min]
struct SessionStatusView: View {
    let usage: UsageOutput?
    let isLoading: Bool
    /// Server-verified data from `claude -p "/usage"` — overrides local estimates when present.
    var claudeUsage: ClaudeUsageInfo? = nil
    /// Called when the user taps the manual-refresh button (↺).
    var onRefresh: (() -> Void)? = nil

    @AppStorage(ClaudePlan.detectedLimitKey) private var detectedLimit: Int = 0
    @AppStorage("manualPlanLimit")           private var manualLimit:   Int = 0

    @State private var showCalibration = false
    @State private var calibrationInput = ""
    @State private var now: Date = Date()
    @State private var isRefreshing = false
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    // MARK: - Helpers

    /// Effective output-token quota (priority: manual > P95 detected > fallback 44K)
    private var planLimit: Int {
        if manualLimit > 1_000 { return manualLimit }
        if detectedLimit > 1_000 { return detectedLimit }
        return 44_000
    }

    /// Badge shows "⚡ 276.2K / 375.2K" when session data is available,
    /// otherwise just the limit. 📌 prefix when manually calibrated.
    private func limitBadgeText(sessionOut: Int?) -> String {
        let limitStr: String
        if manualLimit > 1_000   { limitStr = formatTokens(manualLimit) }
        else if detectedLimit > 1_000 { limitStr = formatTokens(detectedLimit) }
        else { return "⚡ detecting…" }

        let prefix = manualLimit > 1_000 ? "📌" : "⚡"
        if let out = sessionOut {
            return "\(prefix) \(formatTokens(out)) / \(limitStr)"
        }
        return "\(prefix) \(limitStr)"
    }

    private func tokenProgress(_ u: UsageOutput) -> Double {
        if let ci = claudeUsage, !ci.isStale {
            return min(Double(ci.sessionPct) / 100.0, 1.0)
        }
        guard let out = u.sessionOutput else { return u.sessionTokenProgress(planLimit: planLimit) }
        return min(Double(out) / Double(planLimit), 1.0)
    }

    /// Reset text: uses server reset time when available, falls back to JSONL estimate.
    private func resetsInText(for u: UsageOutput) -> String {
        if let ci = claudeUsage, !ci.isStale, let r = ci.sessionReset {
            return ClaudeUsageInfo.resetsInText(from: r)
        }
        return u.resetsInText
    }

    /// True when displaying server-verified data (green dot indicator).
    private var hasServerData: Bool {
        claudeUsage.map { !$0.isStale } ?? false
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if isLoading && usage == nil {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.65)
                        Text("Loading session…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let u = usage {
                    rowLabel(u)
                    rowProgressBar(u)
                    rowBurnRate(u)
                } else {
                    Text("Session usage unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .onReceive(ticker) { t in now = t }
        .sheet(isPresented: $showCalibration) { calibrationSheet }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowLabel(_ u: UsageOutput) -> some View {
        HStack(spacing: 6) {
            Text("Current / total").font(.caption.weight(.medium))

            // Limit source badge (tap = open calibration)
            // Shows "⚡ 276.2K / 375.2K" when session data available
            Button {
                calibrationInput = ""
                showCalibration = true
            } label: {
                Text(limitBadgeText(sessionOut: u.sessionOutput))
                    .font(.caption2)
                    .foregroundStyle(manualLimit > 0 ? Color.accentColor : .secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background((manualLimit > 0 ? Color.accentColor : Color.secondary).opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(manualLimit > 0 ? "手動校正中，點擊重新校正" : "點擊校正：對齊 Claude Desktop 的 % 數值")

            Spacer()

            // Green dot when displaying server-verified data
            if hasServerData {
                Circle()
                    .fill(Color.green.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .help("Server 驗證：數據來自 claude /usage")
            }

            Text(resetsInText(for: u))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .id(now)

            // ↺ Manual refresh button
            if let refresh = onRefresh {
                Button {
                    guard !isRefreshing else { return }
                    isRefreshing = true
                    refresh()
                    // Keep spinning until both JSONL parser (~0.5s) and /usage (~2.1s) finish
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        isRefreshing = false
                    }
                } label: {
                    Image(systemName: isRefreshing ? "arrow.trianglehead.2.clockwise.rotate.90" : "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(isRefreshing ? .degrees(360) : .zero)
                        .animation(isRefreshing
                            ? .linear(duration: 0.7).repeatForever(autoreverses: false)
                            : .default,
                            value: isRefreshing)
                }
                .buttonStyle(.plain)
                .help("立即重新抓取 session 資料")
            }
        }
    }

    @ViewBuilder
    private func rowProgressBar(_ u: UsageOutput) -> some View {
        let progress = tokenProgress(u)
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(progress: progress))
                        .frame(width: geo.size.width * progress, height: 6)
                        .animation(.easeOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 6)

            Text("\(Int(progress * 100))%")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(minWidth: 32, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func rowBurnRate(_ u: UsageOutput) -> some View {
        if let start = u.sessionStart, let reset = u.sessionReset, let out = u.sessionOutput {
            let elapsedH = max(Date().timeIntervalSince(start) / 3600, 0.001)
            let remainH  = max(reset.timeIntervalSinceNow / 3600, 0)
            if elapsedH > 0.1 {
                let burn   = Double(out) / elapsedH
                let estPct = (Double(out) + burn * remainH) / Double(planLimit)
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill").font(.caption2).foregroundStyle(.orange.opacity(0.8))
                    Text("~\(formatTokens(Int(burn)))/h").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text("est. \(Int(min(estPct * 100, 999)))% at reset")
                        .font(.caption).foregroundStyle(burnRateColor(estPct: estPct)).id(now)
                    Spacer()
                    // 5-hour session cost (not all-time)
                    if let cost = u.session5hCostUSD {
                        Text("5hr \(formatCost(cost))")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    private func formatCost(_ usd: Double) -> String {
        usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
    }

    // MARK: - Calibration sheet

    private var calibrationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("校正用量上限").font(.headline)
                Spacer()
                Button("取消") { showCalibration = false }.buttonStyle(.plain).foregroundStyle(.secondary)
            }

            Text("開啟 Claude Desktop，查看「Current session」顯示的 **%**，填入下方反推精確上限。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let u = usage, let out = u.sessionOutput, out > 0 {
                Text("目前近5h output：\(formatTokens(out))")
                    .font(.caption)

                HStack(spacing: 8) {
                    TextField("例：64", text: $calibrationInput)
                        .textFieldStyle(.roundedBorder).frame(width: 72)
                    Text("%").font(.caption)
                    Text("→").font(.caption).foregroundStyle(.secondary)
                    if let pct = Double(calibrationInput), pct > 0, pct <= 100 {
                        let implied = Int(Double(out) / (pct / 100))
                        Text("上限 \(formatTokens(implied))")
                            .font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                    } else {
                        Text("上限 —").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if manualLimit > 0 {
                    Text("目前手動校正：\(formatTokens(manualLimit)) （清除後回到 Auto 偵測）")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("無法校正：sessionOutput 為 0，請稍後再試。")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                if manualLimit > 0 {
                    Button("清除") { manualLimit = 0; showCalibration = false }
                        .buttonStyle(.bordered).foregroundStyle(.red)
                }
                Spacer()
                Button("套用") {
                    if let u = usage, let out = u.sessionOutput, out > 0,
                       let pct = Double(calibrationInput), pct > 0, pct <= 100 {
                        let v = Int(Double(out) / (pct / 100))
                        if v > 5_000 { manualLimit = v; showCalibration = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled({
                    guard let u = usage, let out = u.sessionOutput, out > 0,
                          let pct = Double(calibrationInput), pct > 0, pct <= 100
                    else { return true }
                    return Int(Double(out) / (pct / 100)) <= 5_000
                }())
            }
        }
        .padding(20).frame(width: 360)
    }

    // MARK: - Style helpers

    private func barColor(progress: Double) -> Color {
        progress > 0.85 ? .red : progress > 0.65 ? .orange : Color(NSColor.controlAccentColor)
    }
    private func burnRateColor(estPct: Double) -> Color {
        estPct > 0.95 ? .red : estPct > 0.80 ? .orange : .secondary
    }
    private func formatTokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n)/1_000_000) :
        n >= 1_000     ? String(format: "%.1fK", Double(n)/1_000) : "\(n)"
    }
}
