import AppKit
import Foundation
import Testing
@testable import WakaWaka

struct FloatingPanelLayoutTests {
    @Test func emptyNormalStateIsDimmed() {
        #expect(FloatingPanelLayout.opacity(agentCount: 0, isDegraded: false, base: 0.95) == 0.35)
    }

    @Test func degradedStatePreservesBaseOpacity() {
        #expect(FloatingPanelLayout.opacity(agentCount: 0, isDegraded: true, base: 0.95) == 0.95)
    }

    @Test func offscreenFrameMovesInsideFirstScreenWithoutResizing() {
        let frame = NSRect(x: 1_000, y: 1_000, width: 220, height: 120)
        let screen = NSRect(x: 0, y: 0, width: 800, height: 600)

        let clamped = FloatingPanelPlacement.clamp(frame, into: [screen])

        #expect(screen.contains(clamped))
        #expect(clamped.size == frame.size)
    }

    @Test func barelyVisibleCornerMovesFullyInsideScreen() {
        let frame = NSRect(x: 790, y: 590, width: 220, height: 120)
        let screen = NSRect(x: 0, y: 0, width: 800, height: 600)

        let clamped = FloatingPanelPlacement.clamp(frame, into: [screen])

        #expect(screen.contains(clamped))
        #expect(clamped != frame)
    }

    @Test func fullyVisibleFrameRemainsUnchanged() {
        let frame = NSRect(x: 100, y: 100, width: 220, height: 120)
        let screen = NSRect(x: 0, y: 0, width: 800, height: 600)

        #expect(FloatingPanelPlacement.clamp(frame, into: [screen]) == frame)
    }

    @Test func emptyScreenListLeavesFrameUnchanged() {
        let frame = NSRect(x: 1_000, y: 1_000, width: 220, height: 120)

        #expect(FloatingPanelPlacement.clamp(frame, into: []) == frame)
    }

    @Test func frameOnSecondScreenRemainsUnchanged() {
        let frame = NSRect(x: 900, y: 100, width: 220, height: 120)
        let screens = [
            NSRect(x: 0, y: 0, width: 800, height: 600),
            NSRect(x: 800, y: 0, width: 800, height: 600),
        ]

        #expect(FloatingPanelPlacement.clamp(frame, into: screens) == frame)
    }

    @Test func oversizedFrameAlignsWithFirstScreenTopLeftWithoutResizing() {
        let frame = NSRect(x: 1_000, y: 1_000, width: 900, height: 700)
        let screen = NSRect(x: 100, y: 50, width: 800, height: 600)

        let clamped = FloatingPanelPlacement.clamp(frame, into: [screen])

        #expect(clamped.origin == NSPoint(x: screen.minX, y: screen.maxY - frame.height))
        #expect(clamped.size == frame.size)
    }

    @Test func storedOpacityAboveRangeIsClamped() {
        withIsolatedDefaults { defaults, preferences in
            defaults.set(2.0, forKey: "floatingPanel.opacity")

            #expect(preferences.opacity == 1.0)
        }
    }

    @Test func storedOpacityBelowRangeIsClamped() {
        withIsolatedDefaults { defaults, preferences in
            defaults.set(0.1, forKey: "floatingPanel.opacity")

            #expect(preferences.opacity == 0.35)
        }
    }

    private func withIsolatedDefaults(
        perform assertions: (UserDefaults, FloatingPanelPreferences) -> Void
    ) {
        let suiteName = "FloatingPanelLayoutTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertions(defaults, FloatingPanelPreferences(defaults: defaults))
    }
}
