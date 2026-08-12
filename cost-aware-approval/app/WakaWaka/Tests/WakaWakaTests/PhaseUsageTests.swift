import Foundation
import Testing
@testable import WakaWaka

/// The fixture is real `phase-usage.ts` output (trimmed to two segments), not a
/// hand-written approximation — a Codable model that only ever sees invented
/// JSON drifts from the parser without anything failing.
struct PhaseUsageTests {
    private func loadFixture() throws -> PhaseUsage {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("phase-usage-sample.json")
        return try JSONDecoder().decode(PhaseUsage.self, from: Data(contentsOf: url))
    }

    @Test func decodesRealParserOutput() throws {
        let usage = try loadFixture()

        #expect(usage.granularity == "session")
        #expect(usage.segments.count == 2)
        #expect(!usage.pricingAsOf.isEmpty)
        #expect(usage.toolPhasesVersion >= 1)
        #expect(!usage.warnings.isEmpty, "the report always carries its reading caveats")
    }

    @Test func bucketsReconstructTheSegmentTotal() throws {
        // The parser guarantees conservation; if the Swift model ever mis-maps a
        // bucket the arithmetic stops adding up here rather than in the chart.
        for segment in try loadFixture().segments {
            let calls = Phase.allCases.reduce(0) { $0 + segment.phases[$1].calls }
            let output = Phase.allCases.reduce(0) { $0 + segment.phases[$1].output }
            #expect(calls == segment.total.calls, "calls must sum to the segment total")
            #expect(output == segment.total.output, "output must sum to the segment total")
        }
    }

    @Test func directAndSidechainSplitEachBucket() throws {
        for segment in try loadFixture().segments {
            for phase in Phase.allCases {
                let bucket = segment.phases[phase]
                #expect(bucket.direct.calls + bucket.sidechain.calls == bucket.calls)
                #expect(bucket.direct.output + bucket.sidechain.output == bucket.output)
            }
        }
    }

    @Test func overallSlicesAreOrderedBySizeAndCoverEveryPhase() throws {
        let slices = try loadFixture().overall

        #expect(slices.count == Phase.allCases.count, "every bucket is shown, including empty ones")
        #expect(slices.map(\.output) == slices.map(\.output).sorted(by: >), "largest share first")

        let usage = try loadFixture()
        #expect(slices.reduce(0) { $0 + $1.output } == usage.totalOutput)
    }

    /// Built by decoding rather than a memberwise init, so the production model
    /// stays free of initialisers that exist only for tests.
    private func bucket(costUSD: String) throws -> PhaseBucket {
        let json = """
        {"calls":1,"output":10,"uncachedInput":0,"cacheRead":0,"cacheWrite":0,
         "costUSD":\(costUSD),
         "direct":{"calls":1,"output":10},"sidechain":{"calls":0,"output":0}}
        """
        return try JSONDecoder().decode(PhaseBucket.self, from: Data(json.utf8))
    }

    @Test func aSliceWithAnUnpriceableSegmentReportsNoCost() throws {
        // Summing only the priced part would render as a complete, smaller bill.
        let priced = try bucket(costUSD: "1.5")
        let unpriced = try bucket(costUSD: "null")

        #expect(PhaseSlice(phase: .develop, totals: [priced, priced]).costUSD == 3.0)
        #expect(PhaseSlice(phase: .develop, totals: [priced, unpriced]).costUSD == nil)
    }

    @Test func unknownRateCeilingMatchesThePlan() {
        #expect(PhaseDiagnostics.unknownRateCeiling == 0.25)
    }

    @Test func theDisclaimerRulesOutTheReadingsTheDataCannotSupport() {
        // The plan forbids framing this as productivity or as a basis for
        // comparison; a bar chart invites exactly those readings.
        #expect(PhaseUsage.disclaimer.contains("不是時間分配"))
        #expect(PhaseUsage.disclaimer.contains("生產力"))
        #expect(!PhaseUsage.disclaimer.contains("效率"))
    }

    // MARK: Distribution — the presentation rules the chart depends on

    private func slice(_ phase: Phase, costUSD: String, output: Int = 10) throws -> PhaseSlice {
        let json = """
        {"calls":1,"output":\(output),"uncachedInput":0,"cacheRead":0,"cacheWrite":0,
         "costUSD":\(costUSD),
         "direct":{"calls":1,"output":\(output)},"sidechain":{"calls":0,"output":0}}
        """
        let bucket = try JSONDecoder().decode(PhaseBucket.self, from: Data(json.utf8))
        return PhaseSlice(phase: phase, totals: [bucket])
    }

    @Test func sharesSumToOneWhenEveryBucketCanBeValued() throws {
        let slices = [try slice(.develop, costUSD: "3"), try slice(.verify, costUSD: "1")]
        let model = PhaseDistribution(slices: slices, metric: .cost)

        #expect(!model.isShareUnavailable)
        #expect(model.rows[0].share == 0.75)
        #expect(model.rows[1].share == 0.25)
    }

    @Test func oneUnpriceableBucketWithholdsEveryShare() throws {
        // Renormalising the rest would render $5 of an unknown total as "100%".
        let slices = [try slice(.develop, costUSD: "5"), try slice(.other, costUSD: "null")]
        let model = PhaseDistribution(slices: slices, metric: .cost)

        #expect(model.isShareUnavailable)
        #expect(model.rows.allSatisfy { $0.share == nil }, "no share may be published")
        #expect(model.rows[0].value == 5, "the known amount is still shown")
        #expect(model.rows[1].value == nil)
    }

    @Test func unpriceableBucketsDoNotAffectTheOutputOrCallsViews() throws {
        let slices = [try slice(.develop, costUSD: "5", output: 30),
                      try slice(.other, costUSD: "null", output: 10)]

        for metric in [PhaseMetric.output, .calls] {
            let model = PhaseDistribution(slices: slices, metric: metric)
            #expect(!model.isShareUnavailable, "\(metric.rawValue) is always computable")
            #expect(model.rows.allSatisfy { $0.share != nil })
        }
    }

    @Test func allZeroValuesProduceNoSharesRatherThanDividingByZero() throws {
        let slices = [try slice(.reply, costUSD: "0", output: 0)]
        let model = PhaseDistribution(slices: slices, metric: .output)

        #expect(model.rows.allSatisfy { $0.share == nil })
    }

    // MARK: Service lifecycle

    /// A structurally valid report with no segments — distinguishable from the
    /// two-segment fixture, so a test can tell which load produced the state.
    private func emptyReport() throws -> PhaseUsage {
        let json = """
        {"generatedAt":"2026-01-01T00:00:00Z","granularity":"session",
         "pricingAsOf":"2026-01-01","toolPhasesVersion":1,"segments":[],
         "diagnostics":{"unclassifiedTools":[],"unknownBash":[],"mixedCalls":[],
           "excluded":{"synthetic":0,"noUsage":0},"unknownRate":0,
           "pricedCalls":0,"totalCalls":0},
         "warnings":[]}
        """
        return try JSONDecoder().decode(PhaseUsage.self, from: Data(json.utf8))
    }

    @Test @MainActor func aSupersededLoadCannotReplaceNewerContent() async throws {
        // A 30-day load can take a minute. If it lands after the user switched
        // back to 7 days it must be dropped, not rendered under a "7 天" picker.
        let slow = try loadFixture()       // 2 segments — the 30-day answer
        let fast = try emptyReport()       // 0 segments — the 7-day answer
        let gate = DispatchSemaphore(value: 0)

        let service = PhaseUsageService(loader: { days in
            if days == 30 {
                gate.wait()                // hold the superseded request open
                return slow
            }
            return fast
        })

        service.load(days: 30)             // blocks in the loader
        service.load(days: 7)              // supersedes it

        // Let the 7-day completion land first, so the stale one arrives after
        // the state it would corrupt. Signalling immediately would leave the
        // two completions racing, and the test would pass either way.
        try await Task.sleep(nanoseconds: 250_000_000)
        gate.signal()
        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(service.days == 7)
        guard case .loaded(let shown) = service.state else {
            Issue.record("expected a loaded state, got \(service.state)")
            return
        }
        #expect(shown.segments.isEmpty, "the stale 30-day result must not have won")
    }

    @Test func phaseLabelsAreStable() {
        #expect(Phase.understand.label == "理解")
        #expect(Phase.develop.label == "開發")
        #expect(Phase.verify.label == "驗證")
        #expect(Phase.reply.label == "回覆")
        #expect(Phase.other.label == "其他")
    }
}
