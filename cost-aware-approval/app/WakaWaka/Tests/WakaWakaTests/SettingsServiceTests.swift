import Foundation
import Testing
@testable import WakaWaka

struct SettingsServiceTests {
    @Test func enablingAutoModePersistsWithoutExpiry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        fixture.service.setAutoMode(agent: .codex, enabled: true)

        let persistedState = fixture.service.load().autoMode.codex
        #expect(persistedState.enabled)
        #expect(persistedState.expiresAt == nil)
    }

    @Test func disablingAutoModePersistsDisabledState() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        fixture.service.setAutoMode(agent: .codex, enabled: true)

        fixture.service.setAutoMode(agent: .codex, enabled: false)

        #expect(fixture.service.load().autoMode.codex == .disabled)
    }

    private func makeFixture() throws -> (directoryURL: URL, service: SettingsService) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WakaWakaSettingsServiceTests-\(UUID().uuidString)")
        let settingsURL = directoryURL.appendingPathComponent("settings.json")
        return (directoryURL, SettingsService(settingsURL: settingsURL))
    }
}
