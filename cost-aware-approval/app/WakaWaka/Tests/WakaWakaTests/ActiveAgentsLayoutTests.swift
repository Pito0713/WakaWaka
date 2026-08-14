import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WakaWaka

/// The popover sizes itself from constants rather than from SwiftUI, so a
/// section whose real height exceeds what the arithmetic assumed pushes the
/// footer — auto-mode row and quota bars — off the bottom of the window. That
/// is what happened when ACTIVE AGENTS was first added.
///
/// `AppDelegate` now measures this section instead of estimating it. These
/// tests pin down the measurement itself: that it is non-zero (a laid-out
/// `NSHostingView` returning 0 is the classic silent failure) and that it
/// tracks the content it is supposed to describe.
@MainActor
struct ActiveAgentsLayoutTests {
    /// Mirrors `AppDelegate.activeAgentsHeight` — same wrapper, same width.
    private func measure(_ snapshot: ActiveAgentsSnapshot) -> CGFloat {
        let probe = VStack(alignment: .leading, spacing: 0) {
            ActiveAgentsView(snapshot: snapshot)
        }
        .frame(width: 480)
        return NSHostingView(rootView: probe).fittingSize.height
    }

    private func row(
        project: String = "lake-ui-kit",
        branch: String? = "main",
        tool: String? = "Bash"
    ) -> ActiveAgentRow {
        ActiveAgentRow(
            id: "claude-code:\(project):\(branch ?? "none")",
            kind: .claudeCode,
            projectName: project,
            fullPath: "/workspace/\(project)",
            gitBranch: branch,
            model: "claude-opus-5",
            skill: nil,
            skillSource: nil,
            lastTool: tool,
            state: .working,
            heartbeatAt: Date()
        )
    }

    /// `degraded` picks any status that carries a message; which one it is does
    /// not change the layout, only whether the warning line is drawn.
    private func snapshot(rows: [ActiveAgentRow], degraded: Bool = false) -> ActiveAgentsSnapshot {
        ActiveAgentsSnapshot(
            rows: rows,
            status: degraded ? .permissionDenied : .ok
        )
    }

    @Test func anEmptySnapshotTakesNoSpace() {
        #expect(measure(.empty) == 0)
    }

    @Test func aSingleRowIsMeasuredNotEstimated() {
        let height = measure(snapshot(rows: [row()]))
        // A hosting view that was never laid out reports 0; anything under the
        // height of one line of text means the measurement did not happen.
        #expect(height > 40)
    }

    @Test func heightGrowsWithEachRow() {
        let one = measure(snapshot(rows: [row(project: "a")]))
        let two = measure(snapshot(rows: [row(project: "a"), row(project: "b")]))
        let three = measure(snapshot(rows: [row(project: "a"), row(project: "b"), row(project: "c")]))

        #expect(two > one)
        #expect(three > two)
        // Rows are uniform, so the two increments must agree.
        #expect(abs((two - one) - (three - two)) < 1)
    }

    /// Beyond the cap the list stops growing by a full row — it gains only the
    /// "+N more" line, once, no matter how many are hidden.
    @Test func overflowAddsOneLineNotOneRowPerAgent() {
        let capped = snapshot(rows: (0..<AgentRegistryService.maxRows).map { row(project: "p\($0)") })
        let over = snapshot(rows: (0..<(AgentRegistryService.maxRows + 4)).map { row(project: "p\($0)") })

        let cappedHeight = measure(capped)
        let overHeight = measure(over)
        let perRow = measure(snapshot(rows: [row(project: "a"), row(project: "b")]))
                   - measure(snapshot(rows: [row(project: "a")]))

        #expect(overHeight > cappedHeight)
        #expect(overHeight - cappedHeight < perRow)
    }

    /// A degraded read shows a warning line even with no rows; the popover has
    /// to make room for it or the message is invisible.
    @Test func aStatusMessageIsGivenRoomOnItsOwn() {
        let rowsOnly = measure(snapshot(rows: [row()]))
        let withMessage = measure(snapshot(rows: [row()], degraded: true))
        #expect(withMessage > rowsOnly)

        #expect(measure(snapshot(rows: [], degraded: true)) > 0)
    }
}

