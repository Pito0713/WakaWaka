import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WakaWaka

/// The popover used to size itself from a sum of hand-measured constants, one
/// per section. That went wrong twice: the ACTIVE AGENTS panel was left out of
/// the sum entirely, and the footer's real height was 12pt more than its
/// constant — both times the auto-mode row and the usage bars were pushed off
/// the bottom of the window. In the no-agents case the two errors cancelled,
/// which is how the first one shipped.
///
/// `AppDelegate` now asks SwiftUI. These tests pin down what that measurement
/// has to guarantee: it is real, it grows with content, and the footer is
/// always inside it.
@MainActor
struct PopoverLayoutTests {
    /// The real sizing policy, not a copy of it. A test that measured
    /// `ContentView` itself would keep passing if the popover went back to
    /// summing constants, which is exactly the regression that shipped twice.
    private func popoverHeight(_ model: PopoverViewModel) -> CGFloat {
        PopoverSizing.contentHeight(model: model, width: 480)
    }

    private func footerHeight(_ model: PopoverViewModel) -> CGFloat {
        let probe = VStack(alignment: .leading, spacing: 0) { PopoverFooter(model: model) }
            .frame(width: 480)
        return NSHostingView(rootView: probe).fittingSize.height
    }

    private func agentsHeight(_ snapshot: ActiveAgentsSnapshot) -> CGFloat {
        let probe = VStack(alignment: .leading, spacing: 0) { ActiveAgentsView(snapshot: snapshot) }
            .frame(width: 480)
        return NSHostingView(rootView: probe).fittingSize.height
    }

    private func agentsHeight(_ snapshot: ActiveAgentsSnapshot,
                              contextUsage: [String: ContextUsage]) -> CGFloat {
        let probe = VStack(alignment: .leading, spacing: 0) {
            ActiveAgentsView(snapshot: snapshot, contextUsage: contextUsage)
        }
        .frame(width: 480)
        return NSHostingView(rootView: probe).fittingSize.height
    }

    /// The critical band adds a line of explanation to a row. A line that
    /// changes the layout without changing the measurement is precisely the
    /// defect this file exists to catch — it shipped twice before.
    @Test func theCriticalWarningLineIsMeasured() throws {
        let snapshot = ActiveAgentsSnapshot(rows: [row("alpha")], status: .ok)
        let id = try #require(snapshot.rows.first?.id)

        let calm = try #require(ContextUsage(usedTokens: 400_000, limitTokens: 1_000_000))
        let full = try #require(ContextUsage(usedTokens: 910_000, limitTokens: 1_000_000))
        #expect(calm.band == .normal && full.band == .critical)

        let plain = agentsHeight(snapshot, contextUsage: [:])
        let metered = agentsHeight(snapshot, contextUsage: [id: calm])
        let warned = agentsHeight(snapshot, contextUsage: [id: full])

        #expect(metered == plain, "a meter rides inside a row that already exists")
        #expect(warned > metered, "the warning line adds height and must be measured")
    }

    private func row(_ name: String) -> ActiveAgentRow {
        ActiveAgentRow(
            id: "claude-code:\(name)", kind: .claudeCode, pid: 1, pidStartedAt: nil,
            projectName: name,
            fullPath: "/workspace/\(name)", gitBranch: "main", model: "claude-opus-5",
            skill: nil, skillSource: nil, lastTool: "Bash",
            state: .working, heartbeatAt: Date()
        )
    }

    private func model(agents: Int = 0, degraded: Bool = false, pending: Int = 0) throws -> PopoverViewModel {
        let m = PopoverViewModel()
        if agents > 0 || degraded {
            m.activeAgents = ActiveAgentsSnapshot(
                rows: (0..<agents).map { row("p\($0)") },
                status: degraded ? .permissionDenied : .ok
            )
        }
        if pending > 0 {
            let json = #"{"agent":"claude-code","tool_name":"Bash","session_id":"s","risk_level":"medium","timestamp":"2026-08-14T00:00:00Z"}"#
            let item = try JSONDecoder().decode(PendingData.self, from: Data(json.utf8))
            m.pendingItems = Array(repeating: item, count: pending)
        }
        return m
    }

    @Test func theMeasurementIsRealNotZero() throws {
        // A hosting view that was never laid out reports 0 — the classic silent
        // failure of this approach, and it would collapse the whole popover.
        #expect(try popoverHeight(model()) > 150)
    }

    /// The bug that was visible on screen: the panel appeared, the window did
    /// not grow, and the quota bars were cut off.
    @Test func addingAgentsGrowsThePopoverByTheirFullHeight() throws {
        let base = try popoverHeight(model())

        for count in 1...3 {
            let m = try model(agents: count)
            let grown = popoverHeight(m)
            let panel = agentsHeight(m.activeAgents)

            #expect(grown - base == panel,
                    "\(count) agents: the panel must add its own height, not absorb it")
        }
    }

    /// Whatever else is on screen, the footer has to fit inside the window —
    /// it holds the auto-mode toggles and the quota bars.
    @Test func theFooterAlwaysFitsInsideTheMeasuredHeight() throws {
        for (agents, pending) in [(0, 0), (3, 0), (0, 1), (3, 5), (5, 20)] {
            let m = try model(agents: agents, pending: pending)
            let panel = m.activeAgents.isEmpty ? 0 : agentsHeight(m.activeAgents)
            let remaining = popoverHeight(m) - panel - footerHeight(m)

            #expect(remaining >= 0,
                    "agents=\(agents) pending=\(pending): footer does not fit")
        }
    }

    /// The approval list scrolls past its cap so the footer stays visible. If
    /// the popover kept growing with the queue it would run off the screen.
    @Test func aLongQueueScrollsRatherThanGrowingWithoutBound() throws {
        let five = try popoverHeight(model(pending: 5))
        let twenty = try popoverHeight(model(pending: 20))
        let hundred = try popoverHeight(model(pending: 100))

        #expect(twenty > five)
        #expect(hundred == twenty, "growth stops at the ScrollView's cap")
    }

    /// What the popover is actually set to — the number that was wrong on
    /// screen. Measuring the view proves nothing about what is done with it.
    @Test func thePopoverIsResizedToWhatTheViewNeeds() throws {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 480, height: 100)

        let idle = try model()
        PopoverSizing.apply(to: popover, model: idle, width: 480, animated: false)
        let base = popover.contentSize.height
        #expect(base == popoverHeight(idle))

        let busy = try model(agents: 3)
        PopoverSizing.apply(to: popover, model: busy, width: 480, animated: false)
        #expect(popover.contentSize.height - base == agentsHeight(busy.activeAgents),
                "the popover must grow by the panel's height, not keep its old size")
    }

    /// A degraded read shows a warning line; the window has to make room for it
    /// or the user is told nothing at all.
    @Test func aStatusMessageIsGivenRoom() throws {
        let quiet = try popoverHeight(model(agents: 1))
        let warned = try popoverHeight(model(agents: 1, degraded: true))
        #expect(warned > quiet)

        // With no rows at all, the warning alone still has to open the panel.
        #expect(try popoverHeight(model(degraded: true)) > popoverHeight(model()))
    }
}
