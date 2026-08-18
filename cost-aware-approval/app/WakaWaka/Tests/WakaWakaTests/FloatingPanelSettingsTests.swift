import Foundation
import Testing
@testable import WakaWaka

@MainActor
struct FloatingPanelSettingsTests {
    @Test func settingPinUpdatesPreferencesAndModel() {
        withController { controller, preferences in
            controller.setPinned(true)

            #expect(preferences.isPinned)
            #expect(controller.model.isPinned)
        }
    }

    @Test func settingOpacityUpdatesPreferencesAndModel() {
        withController { controller, preferences in
            controller.setOpacity(0.5)

            #expect(preferences.opacity == 0.5)
            #expect(controller.model.baseOpacity == 0.5)
        }
    }

    private func withController(
        perform assertions: (FloatingAgentsPanelController, FloatingPanelPreferences) -> Void
    ) {
        let suiteName = "FloatingPanelSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = FloatingPanelPreferences(defaults: defaults)
        assertions(FloatingAgentsPanelController(preferences: preferences), preferences)
    }
}
