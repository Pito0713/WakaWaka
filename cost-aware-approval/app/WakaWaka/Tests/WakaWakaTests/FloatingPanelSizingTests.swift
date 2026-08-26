import AppKit
import Foundation
import Testing
@testable import WakaWaka

@MainActor
struct FloatingPanelSizingTests {
    @Test func measuredContentHasNonzeroSize() {
        let size = contentSize(snapshot: snapshot(agentCount: 1))

        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func emptySnapshotKeepsNonzeroSize() {
        let size = contentSize(snapshot: .empty)

        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func heightGrowsWithAgentCount() {
        let oneAgent = contentSize(snapshot: snapshot(agentCount: 1))
        let threeAgents = contentSize(snapshot: snapshot(agentCount: 3))

        #expect(threeAgents.height > oneAgent.height)
    }

    /// The HUD no longer resizes under the pointer, so agent count must be the
    /// only thing that moves its width — a list that widened as rows arrived
    /// would drift out from under wherever the user parked it.
    @Test func widthIsConstantAcrossStates() {
        let empty = contentSize(snapshot: .empty)
        let populated = contentSize(snapshot: snapshot(agentCount: 3))
        let degraded = contentSize(snapshot: ActiveAgentsSnapshot(rows: [], status: .permissionDenied))

        #expect(empty.width == FloatingPanelLayout.width)
        #expect(populated.width == FloatingPanelLayout.width)
        #expect(degraded.width == FloatingPanelLayout.width)
    }

    @Test func degradedEmptySnapshotKeepsNonzeroSize() {
        let degraded = ActiveAgentsSnapshot(rows: [], status: .permissionDenied)
        let size = contentSize(snapshot: degraded)

        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    /// The dot used to carry the registry failure in its tooltip. With the dot
    /// gone the message has to occupy a row, and that row has to be measured.
    @Test func degradedStatusIncreasesMeasuredHeight() {
        let healthy = contentSize(snapshot: ActiveAgentsSnapshot(rows: [], status: .ok))
        let degraded = contentSize(snapshot: ActiveAgentsSnapshot(rows: [], status: .permissionDenied))

        #expect(degraded.height > healthy.height)
    }

    @Test func focusErrorIncreasesMeasuredHeight() {
        let activeSnapshot = snapshot(agentCount: 2)
        let modelWithoutError = model(snapshot: activeSnapshot)
        let modelWithError = model(snapshot: activeSnapshot)
        modelWithError.focusError = "找不到對應的終端機視窗"

        let heightWithoutError = FloatingPanelSizing.contentSize(model: modelWithoutError).height
        let heightWithError = FloatingPanelSizing.contentSize(model: modelWithError).height

        #expect(heightWithError > heightWithoutError)
    }

    /// The HUD shows no warning text, so a meter must not change its height —
    /// it sits inline in a row that already exists. Pinned because the opposite
    /// mistake (a line that grows the panel without being measured) is the one
    /// this file was written for.
    @Test func aMeterDoesNotChangeTheHUDsHeight() {
        let active = snapshot(agentCount: 2)
        let plain = model(snapshot: active)
        let metered = model(snapshot: active)
        metered.contextUsage = Dictionary(uniqueKeysWithValues: active.rows.map {
            ($0.id, ContextUsage(usedTokens: 910_000, limitTokens: 1_000_000)!)
        })

        #expect(FloatingPanelSizing.contentSize(model: metered).height
                == FloatingPanelSizing.contentSize(model: plain).height)
        #expect(FloatingPanelSizing.contentSize(model: metered).width
                == FloatingPanelSizing.contentSize(model: plain).width)
    }

    private func contentSize(snapshot: ActiveAgentsSnapshot) -> NSSize {
        FloatingPanelSizing.contentSize(model: model(snapshot: snapshot))
    }

    private func model(snapshot: ActiveAgentsSnapshot) -> FloatingPanelModel {
        FloatingPanelModel(snapshot: snapshot, baseOpacity: 1)
    }

    private func snapshot(agentCount: Int) -> ActiveAgentsSnapshot {
        ActiveAgentsSnapshot(
            rows: (0..<agentCount).map { row(projectName: "project-\($0)") },
            status: .ok
        )
    }

    private func row(projectName: String) -> ActiveAgentRow {
        ActiveAgentRow(
            id: "claude-code:\(projectName)",
            kind: .claudeCode,
            pid: 1,
            pidStartedAt: nil,
            projectName: projectName,
            fullPath: "/workspace/\(projectName)",
            gitBranch: "main",
            model: "claude-opus-5",
            skill: nil,
            skillSource: nil,
            lastTool: "Bash",
            state: .working,
            heartbeatAt: Date(timeIntervalSince1970: 1_786_982_400)
        )
    }
}
