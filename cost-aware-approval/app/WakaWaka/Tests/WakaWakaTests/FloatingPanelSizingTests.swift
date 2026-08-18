import AppKit
import Foundation
import Testing
@testable import WakaWaka

@MainActor
struct FloatingPanelSizingTests {
    @Test func measuredContentHasNonzeroSize() {
        let size = contentSize(snapshot: snapshot(agentCount: 1), mode: .compact)

        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func emptySnapshotKeepsNonzeroSize() {
        let size = contentSize(snapshot: .empty, mode: .dot)

        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func compactHeightGrowsWithAgentCount() {
        let oneAgent = contentSize(snapshot: snapshot(agentCount: 1), mode: .compact)
        let threeAgents = contentSize(snapshot: snapshot(agentCount: 3), mode: .compact)

        #expect(threeAgents.height > oneAgent.height)
    }

    @Test func widerModesUseMoreHorizontalSpace() {
        let activeSnapshot = snapshot(agentCount: 1)
        let dot = contentSize(snapshot: activeSnapshot, mode: .dot)
        let compact = contentSize(snapshot: activeSnapshot, mode: .compact)
        let expanded = contentSize(snapshot: activeSnapshot, mode: .expanded)

        #expect(expanded.width > compact.width)
        #expect(compact.width > dot.width)
    }

    @Test func degradedEmptySnapshotKeepsNonzeroSize() {
        let degraded = ActiveAgentsSnapshot(rows: [], status: .permissionDenied)
        let size = contentSize(snapshot: degraded, mode: .dot)

        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func expandedMeasurementIgnoresCompactPreferredMode() {
        let activeSnapshot = snapshot(agentCount: 3)
        let compactModel = measurementModel(snapshot: activeSnapshot, preferredMode: .compact)
        let expandedModel = measurementModel(snapshot: activeSnapshot, preferredMode: .expanded)

        let compactPreferredSize = FloatingPanelSizing.contentSize(model: compactModel, mode: .expanded)
        let expandedPreferredSize = FloatingPanelSizing.contentSize(model: expandedModel, mode: .expanded)

        #expect(compactPreferredSize.height == expandedPreferredSize.height)
    }

    @Test func focusErrorIncreasesMeasuredHeight() {
        let activeSnapshot = snapshot(agentCount: 2)
        let modelWithoutError = measurementModel(snapshot: activeSnapshot, preferredMode: .compact)
        let modelWithError = measurementModel(snapshot: activeSnapshot, preferredMode: .compact)
        modelWithError.focusError = "找不到對應的終端機視窗"

        let heightWithoutError = FloatingPanelSizing.contentSize(model: modelWithoutError, mode: .compact).height
        let heightWithError = FloatingPanelSizing.contentSize(model: modelWithError, mode: .compact).height

        #expect(heightWithError > heightWithoutError)
    }

    private func contentSize(snapshot: ActiveAgentsSnapshot, mode: FloatingPanelMode) -> NSSize {
        let model = FloatingPanelModel(
            snapshot: snapshot,
            preferredMode: mode,
            isPinned: true,
            baseOpacity: 1
        )
        return FloatingPanelSizing.contentSize(model: model, mode: mode)
    }

    private func measurementModel(
        snapshot: ActiveAgentsSnapshot,
        preferredMode: FloatingPanelMode
    ) -> FloatingPanelModel {
        FloatingPanelModel(
            snapshot: snapshot,
            preferredMode: preferredMode,
            isPinned: true,
            baseOpacity: 1
        )
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
