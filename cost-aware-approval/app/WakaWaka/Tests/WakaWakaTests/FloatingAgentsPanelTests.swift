import AppKit
import Testing
@testable import WakaWaka

@MainActor
struct FloatingAgentsPanelTests {
    @Test func panelUsesNonactivatingBehavior() {
        let panel = FloatingAgentsPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 120))

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.level == .floating)
    }

    @Test func panelAppearsAcrossDesktopContexts() {
        let panel = FloatingAgentsPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 120))

        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.stationary))
    }

    @Test func showingPanelDoesNotActivateApplication() {
        let application = NSApplication.shared
        #expect(!application.isActive, "the precondition must be meaningful before showing the panel")

        let controller = FloatingAgentsPanelController()
        controller.show()
        defer { controller.hide() }

        #expect(!application.isActive, "ordering the HUD forward must not activate WakaWaka")
    }
}
