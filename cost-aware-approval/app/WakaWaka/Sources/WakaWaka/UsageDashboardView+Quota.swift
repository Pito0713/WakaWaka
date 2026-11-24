import SwiftUI

/// The live quota section: Claude 5h and weekly, Codex windows, burn rate and plan calibration.
extension UsageDashboardView {
    // MARK: Live quota

    var liveQuotaSection: some View {
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

    func claudeQuotaRow(_ snapshot: LiveQuotaSnapshot) -> some View {
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
    func claudeWeeklyQuotaRow(_ server: ClaudeUsageInfo?) -> some View {
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
    func codexQuotaRow(_ state: CodexUsageState) -> some View {
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

    func codexWindowQuotaRow(_ usage: CodexWindowUsage, info: CodexUsageInfo) -> some View {
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

    func unavailableQuotaRow(label: String, message: String) -> some View {
        HStack {
            Text(label).font(.callout.weight(.medium))
            Spacer()
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    func quotaProgressBar(progress: Double, percentText: String) -> some View {
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
    func claudeBurnRate(_ usage: UsageOutput?) -> some View {
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

    var calibrationSheet: some View {
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

    var parsedCalibrationLimit: Int? {
        guard let limit = Int(calibrationInput), limit > 1_000 else { return nil }
        return limit
    }

    var planLimit: Int {
        if manualPlanLimit > 1_000 { return manualPlanLimit }
        if detectedLimit > 1_000 { return detectedLimit }
        return 44_000
    }

    func claudeProgress(_ snapshot: LiveQuotaSnapshot) -> Double {
        if let server = snapshot.claudeServer, !server.isStale {
            return clampedProgress(Double(server.sessionPct) / 100)
        }
        guard let usage = snapshot.claudeUsage else { return 0 }
        return clampedProgress(usage.sessionTokenProgress(planLimit: planLimit))
    }

    func claudeResetText(_ snapshot: LiveQuotaSnapshot) -> String {
        if let server = snapshot.claudeServer,
           !server.isStale,
           let reset = server.sessionReset {
            return compactResetText(reset)
        }
        return snapshot.claudeUsage?.resetsInText ?? "—"
    }

    func compactResetText(_ reset: Date) -> String {
        let remainingSeconds = Int(reset.timeIntervalSinceNow)
        guard remainingSeconds > 0 else { return "Resetting…" }
        let days = remainingSeconds / 86_400
        if days == 0 { return ClaudeUsageInfo.resetsInText(from: reset) }
        let hours = (remainingSeconds % 86_400) / 3_600
        return hours > 0 ? "Resets in \(days)d \(hours)h" : "Resets in \(days)d"
    }

    func freshnessIndicator(isStale: Bool, helpText: String? = nil) -> some View {
        Circle()
            .fill(isStale ? Color.orange : Color.green.opacity(0.85))
            .frame(width: 6, height: 6)
            .help(helpText ?? (isStale ? "資料已過期" : "資料為最新"))
    }

    func quotaBarColor(_ progress: Double) -> Color {
        progress > 0.85 ? .red : progress > 0.65 ? .orange : Color(nsColor: .controlAccentColor)
    }

    func burnRateColor(_ progress: Double) -> Color {
        progress > 0.95 ? .red : progress > 0.80 ? .orange : .secondary
    }

    func clampedProgress(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }
}
