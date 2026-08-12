import Foundation

// MARK: - phase-usage.ts output

/// Where a window's tokens went, bucketed by activity phase.
///
/// This is a distribution of tool activity, not a measure of effort, time or
/// productivity — see `PhaseUsage.disclaimer`. The wording matters: the plan
/// rules out framing any of this as efficiency or as a basis for comparison.
struct PhaseUsage: Decodable {
    let generatedAt: String
    /// Only `session` is produced today; prompt granularity is deferred.
    let granularity: String
    let pricingAsOf: String
    let toolPhasesVersion: Int
    let segments: [PhaseSegment]
    let diagnostics: PhaseDiagnostics
    let warnings: [String]

    var isEmpty: Bool { segments.isEmpty }

    /// Total output across every segment — the denominator for the bars.
    var totalOutput: Int { segments.reduce(0) { $0 + $1.total.output } }

    /// Buckets summed across segments, largest share first.
    var overall: [PhaseSlice] {
        let slices = Phase.allCases.map { phase in
            PhaseSlice(phase: phase, totals: segments.map { $0.phases[phase] })
        }
        return slices.sorted { $0.output > $1.output }
    }

    /// Share of all output produced inside subagent (sidechain) work.
    var sidechainShare: Double {
        let total = totalOutput
        guard total > 0 else { return 0 }
        let sidechain = segments.reduce(0) { sum, segment in
            sum + Phase.allCases.reduce(0) { $0 + segment.phases[$1].sidechain.output }
        }
        return Double(sidechain) / Double(total)
    }
}

/// The five buckets. `reply` is a response that invoked no tools at all;
/// `other` is everything the classifier could not place.
enum Phase: String, CaseIterable, Identifiable {
    case understand, develop, verify, reply, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .understand: return "理解"
        case .develop:    return "開發"
        case .verify:     return "驗證"
        case .reply:      return "回覆"
        case .other:      return "其他"
        }
    }
}

struct PhaseSegment: Decodable, Identifiable {
    let id: String
    let label: String
    let startedAt: String
    let total: PhaseTotals
    let phases: PhaseBuckets
}

struct PhaseTotals: Decodable {
    let calls: Int
    let output: Int
    let uncachedInput: Int
    let cacheRead: Int
    let cacheWrite: Int
    /// Nil when any call in the bucket used a model with no published price —
    /// a partial figure would read as a complete one.
    let costUSD: Double?
}

/// Sidechain (subagent) work splits within each bucket rather than forming a
/// sixth one, so a subagent's own understand/develop/verify structure survives.
struct PhaseBucket: Decodable {
    let calls: Int
    let output: Int
    let uncachedInput: Int
    let cacheRead: Int
    let cacheWrite: Int
    let costUSD: Double?
    let direct: PhaseSplit
    let sidechain: PhaseSplit
}

struct PhaseSplit: Decodable {
    let calls: Int
    let output: Int
}

struct PhaseBuckets: Decodable {
    let understand: PhaseBucket
    let develop: PhaseBucket
    let verify: PhaseBucket
    let reply: PhaseBucket
    let other: PhaseBucket

    subscript(phase: Phase) -> PhaseBucket {
        switch phase {
        case .understand: return understand
        case .develop:    return develop
        case .verify:     return verify
        case .reply:      return reply
        case .other:      return other
        }
    }
}

struct PhaseDiagnostics: Decodable {
    let unclassifiedTools: [UnclassifiedTool]
    let unknownBash: [UnknownBashHead]
    let mixedCalls: [MixedCallCombo]
    let excluded: ExcludedCounts
    /// Share of output that landed in `other`. Above `unknownRateCeiling` the
    /// distribution is not trustworthy and the UI says so.
    let unknownRate: Double
    let pricedCalls: Int
    let totalCalls: Int

    /// The plan's stop-and-rethink threshold for classifier coverage.
    static let unknownRateCeiling = 0.25

    var isUnknownRateTooHigh: Bool { unknownRate > Self.unknownRateCeiling }

    /// True when some calls could not be priced, so cost figures are partial.
    var hasPricingGap: Bool { pricedCalls < totalCalls }
}

struct UnclassifiedTool: Decodable, Identifiable {
    let name: String
    let calls: Int
    let output: Int
    var id: String { name }
}

struct UnknownBashHead: Decodable, Identifiable {
    let head: String
    let calls: Int
    let output: Int
    var id: String { head }
}

struct MixedCallCombo: Decodable, Identifiable {
    let combo: String
    let calls: Int
    var id: String { combo }
}

struct ExcludedCounts: Decodable {
    let synthetic: Int
    let noUsage: Int
}

// MARK: - Display helpers

/// One bucket rolled up across every segment in the window.
struct PhaseSlice: Identifiable {
    let phase: Phase
    let calls: Int
    let output: Int
    /// Nil when any contributing segment had an unpriceable call.
    let costUSD: Double?
    let sidechainOutput: Int

    var id: String { phase.rawValue }

    init(phase: Phase, totals: [PhaseBucket]) {
        self.phase = phase
        self.calls = totals.reduce(0) { $0 + $1.calls }
        self.output = totals.reduce(0) { $0 + $1.output }
        self.sidechainOutput = totals.reduce(0) { $0 + $1.sidechain.output }
        // One missing price makes the sum an under-report, so drop the whole
        // figure rather than showing a confident partial total.
        self.costUSD = totals.contains { $0.costUSD == nil }
            ? nil
            : totals.reduce(0) { $0 + ($1.costUSD ?? 0) }
    }

    func value(for metric: PhaseMetric) -> Double? {
        switch metric {
        case .output: return Double(output)
        case .calls:  return Double(calls)
        case .cost:   return costUSD
        }
    }
}

/// The three metrics are shown side by side rather than one being "the" answer:
/// `output` measures generation volume, not effort.
enum PhaseMetric: String, CaseIterable, Identifiable {
    case output = "Output"
    case calls  = "次數"
    case cost   = "成本"

    var id: String { rawValue }
}

/// One rendered row: the bucket's value plus its share of the whole.
struct PhaseRow: Identifiable {
    let phase: Phase
    let calls: Int
    /// Nil when the metric cannot be computed for this bucket (unpriced cost).
    let value: Double?
    /// Nil when no honest share can be computed — see `PhaseDistribution`.
    let share: Double?

    var id: String { phase.rawValue }
}

/// Turns slices into rows, and decides whether a share is publishable at all.
///
/// The rule that matters: if any bucket's value is missing, the remaining ones
/// are NOT renormalised to 100%. Doing that turns "we could price $5 of an
/// unknown total" into "this phase is 100% of cost" — a partial figure wearing
/// the costume of a complete one, which is the failure the whole pricing path
/// is built to avoid. Values still show; only the shares are withheld.
struct PhaseDistribution {
    let rows: [PhaseRow]
    /// True when shares were withheld because some bucket could not be valued.
    let isShareUnavailable: Bool

    init(slices: [PhaseSlice], metric: PhaseMetric) {
        let values = slices.map { $0.value(for: metric) }
        let hasGap = values.contains(nil)
        let total = values.compactMap { $0 }.reduce(0, +)
        let canShare = !hasGap && total > 0

        self.isShareUnavailable = hasGap
        self.rows = zip(slices, values).map { slice, value in
            PhaseRow(
                phase: slice.phase,
                calls: slice.calls,
                value: value,
                share: canShare ? (value ?? 0) / total : nil
            )
        }
    }
}

extension PhaseUsage {
    /// Shown under the bars. Deliberately rules out the readings the data
    /// cannot support, because a bar chart invites exactly those readings.
    static let disclaimer = """
        這是「工具活動的 token 分佈」，不是時間分配、工作量或生產力指標。\
        不可用於人員、模型或專案之間的比較。
        """
}
