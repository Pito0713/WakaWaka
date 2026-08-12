import SwiftUI

/// The "活動分佈" tab: where the window's tokens went, by activity phase.
///
/// Design constraints from phase-usage-plan.md §9, all of them about not
/// overclaiming:
///   - It is called 活動分佈, never 效率 or 生產力.
///   - Above the classifier's coverage ceiling the numbers are still shown, but
///     with a warning that they are not trustworthy — hiding them would just
///     make the gap invisible.
///   - No leaderboard, no score, no red/green thresholds, no cross-comparison.
struct PhaseUsageView: View {
    @ObservedObject var service: PhaseUsageService
    @Binding var metric: PhaseMetric

    var body: some View {
        switch service.state {
        case .loading:
            ProgressView("讀取中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            status(icon: "exclamationmark.triangle", text: message)
        case .loaded(let data):
            if data.isEmpty {
                status(icon: "tray", text: "此期間沒有活動資料")
            } else {
                loaded(data)
            }
        }
    }

    private func status(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loaded(_ data: PhaseUsage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if data.diagnostics.isUnknownRateTooHigh {
                    unknownRateWarning(data.diagnostics.unknownRate)
                }
                distribution(data)
                disclaimer
                // The parser's own caveats — chiefly that cache reads make
                // later-session phases systematically dearer, which is about
                // when the work happened, not what the activity costs. Leaving
                // these in the JSON would hide the limits from the only person
                // who reads the chart.
                ForEach(data.warnings, id: \.self) { caption($0) }
                if metric == .cost {
                    caption("成本為標準 API list price 估算（定價日期 \(data.pricingAsOf)），非實際帳單；不含 fast mode 與長 context 加價")
                }
                Divider()
                unclassifiedDetail(data.diagnostics)
            }
            .padding(16)
        }
    }

    // MARK: Warning

    private func unknownRateWarning(_ rate: Double) -> some View {
        Label(
            "未分類比例 \(percent(rate)) — 分類品質不足，以下數字僅供參考",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Distribution

    private func distribution(_ data: PhaseUsage) -> some View {
        let model = PhaseDistribution(slices: data.overall, metric: metric)

        return VStack(alignment: .leading, spacing: 10) {
            Text("活動分佈（\(metric.rawValue)）").font(.subheadline.weight(.semibold))
            ForEach(model.rows) { row in
                phaseRow(row)
            }
            if model.isShareUnavailable {
                caption("部分呼叫無法定價，因此不計算成本佔比 —— 只顯示已知金額，不以剩餘部分湊成 100%")
            }
            if data.sidechainShare > 0 {
                // Named as output share explicitly: it is computed from output
                // regardless of which metric the bars are showing.
                caption("其中 subagent 佔 output \(percent(data.sidechainShare))")
            }
        }
    }

    private func phaseRow(_ row: PhaseRow) -> some View {
        HStack(spacing: 10) {
            Text(row.phase.label)
                .font(.callout)
                .frame(width: 36, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: barWidth(row.share, available: geo.size.width))
                }
            }
            .frame(height: 14)

            Text(row.share.map(percent) ?? "—")
                .font(.callout.monospacedDigit())
                .frame(width: 52, alignment: .trailing)

            Text(formatted(row.value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)

            Text("\(row.calls) calls")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 76, alignment: .trailing)
        }
    }

    /// Bar length is the share of the total, the same number printed beside it.
    /// Scaling to the largest bucket instead would fill the bar for whichever
    /// phase happens to lead — a 40% bucket would read as 100%.
    private func barWidth(_ share: Double?, available: CGFloat) -> CGFloat {
        guard let share, share > 0 else { return 0 }
        return max(2, available * CGFloat(min(share, 1)))
    }

    // MARK: Diagnostics

    private func unclassifiedDetail(_ diagnostics: PhaseDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("未分類明細").font(.subheadline.weight(.semibold))

            if diagnostics.unknownBash.isEmpty && diagnostics.unclassifiedTools.isEmpty {
                caption("沒有未分類的工具或指令")
            } else {
                ForEach(diagnostics.unknownBash.prefix(5)) { entry in
                    detailRow(name: "Bash（無法判定）  \(entry.head)",
                              calls: entry.calls, output: entry.output)
                }
                ForEach(diagnostics.unclassifiedTools.prefix(5)) { entry in
                    detailRow(name: entry.name, calls: entry.calls, output: entry.output)
                }
            }

            if diagnostics.excluded.synthetic > 0 || diagnostics.excluded.noUsage > 0 {
                caption("已排除：\(diagnostics.excluded.synthetic) 筆本機佔位、\(diagnostics.excluded.noUsage) 筆無用量記錄（不計入任何分類）")
            }
        }
    }

    private func detailRow(name: String, calls: Int, output: Int) -> some View {
        HStack {
            Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(calls) calls").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(formatTokens(output)).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
    }

    // MARK: Footnotes

    private var disclaimer: some View {
        Label(PhaseUsage.disclaimer, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Formatting

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        return metric == .cost ? String(format: "$%.2f", value) : formatTokens(Int(value))
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func percent(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }
}
