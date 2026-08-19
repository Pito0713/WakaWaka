import AppKit
import Testing
@testable import WakaWaka

@MainActor
struct FloatingPanelFocusErrorTests {
    @Test func updatePublishesFocusErrorAndGrowsPanel() {
        let suiteName = "FloatingPanelFocusErrorTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = FloatingPanelPreferences(defaults: defaults)
        let controller = FloatingAgentsPanelController(preferences: preferences)

        controller.update(snapshot: snapshot)
        controller.update(focusError: nil)
        let heightWithoutError = controller.panel.frame.height
        controller.update(focusError: "找不到對應的終端機視窗")

        #expect(controller.model.focusError == "找不到對應的終端機視窗")
        #expect(controller.panel.frame.height > heightWithoutError)
    }

    private var snapshot: ActiveAgentsSnapshot {
        ActiveAgentsSnapshot(rows: [row], status: .ok)
    }

    private var row: ActiveAgentRow {
        ActiveAgentRow(
            id: "claude-code:project",
            kind: .claudeCode,
            pid: 1,
            pidStartedAt: nil,
            projectName: "project",
            fullPath: "/workspace/project",
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
