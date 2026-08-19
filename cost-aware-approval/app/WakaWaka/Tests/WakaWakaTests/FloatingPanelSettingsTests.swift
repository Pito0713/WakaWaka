import Foundation
import Testing
@testable import WakaWaka

@MainActor
struct FloatingPanelSettingsTests {
    @Test func settingOpacityUpdatesPreferencesAndModel() {
        withController { controller, preferences in
            controller.setOpacity(0.5)

            #expect(preferences.opacity == 0.5)
            #expect(controller.model.baseOpacity == 0.5)
        }
    }

    /// The stored opacity has to reach the model at construction, not only when
    /// the context menu changes it — otherwise every launch starts back at 0.95.
    @Test func storedOpacitySeedsTheModel() {
        withController(opacity: 0.5) { controller, _ in
            #expect(controller.model.baseOpacity == 0.5)
        }
    }

    private func withController(
        opacity: Double? = nil,
        perform assertions: (FloatingAgentsPanelController, FloatingPanelPreferences) -> Void
    ) {
        let suiteName = "FloatingPanelSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = FloatingPanelPreferences(defaults: defaults)
        if let opacity { preferences.opacity = opacity }
        assertions(FloatingAgentsPanelController(preferences: preferences), preferences)
    }
}
