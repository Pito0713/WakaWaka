import AppKit
import SwiftUI

/// A persistent HUD that accepts interaction without activating the accessory app.
final class FloatingAgentsPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [
                .nonactivatingPanel, // Prevent panel clicks from activating the accessory app.
                .borderless,         // Let the compact HUD content define the entire visual surface.
                .utilityWindow,      // Preserve panel behavior intended for lightweight auxiliary UI.
            ],
            backing: .buffered,
            defer: false
        )

        // A floating panel remains above ordinary application windows without covering system UI.
        isFloatingPanel = true
        // Controls can request key status when needed without making every panel click take focus.
        becomesKeyOnlyIfNeeded = true
        // The status-bar level would obscure menus and notifications.
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,      // Keep the HUD visible when the user switches desktops.
            .fullScreenAuxiliary,   // Keep the HUD available beside another app in full screen.
            .stationary,            // Prevent the HUD from flying with Mission Control animations.
        ]
        // A borderless panel has no title bar that the user could otherwise drag.
        isMovableByWindowBackground = true
        // Losing application activation must not hide a persistent cross-app HUD.
        hidesOnDeactivate = false
        // The controller reuses the same panel after it has been closed or hidden.
        isReleasedWhenClosed = false
        // A clear backing lets the hosted HUD draw rounded or irregular edges.
        backgroundColor = .clear
        // AppKit must composite the clear backing instead of treating the window as a solid rectangle.
        isOpaque = false
        // A shadow keeps the borderless HUD distinguishable over similarly colored windows.
        hasShadow = true
    }

    // Borderless windows reject key status by default, which breaks controls that genuinely need it.
    override var canBecomeKey: Bool { true }

    // Main-window status carries foreground-app semantics that this HUD must never claim.
    override var canBecomeMain: Bool { false }
}

/// Owns the floating panel without changing application activation.
final class FloatingAgentsPanelController: NSWindowController {
    let panel: FloatingAgentsPanel
    private let preferences: FloatingPanelPreferences
    let model: FloatingPanelModel
    private var currentMode: FloatingPanelMode = .dot
    private var screenParametersObserver: NSObjectProtocol?

    init(
        contentRect: NSRect = NSRect(x: 0, y: 0, width: 220, height: 120),
        preferences: FloatingPanelPreferences = FloatingPanelPreferences(),
        onFocus: @escaping (ActiveAgentRow) -> Void = { _ in }
    ) {
        let panel = FloatingAgentsPanel(contentRect: contentRect)
        let model = FloatingPanelModel(
            snapshot: .empty,
            preferredMode: preferences.mode,
            isPinned: preferences.isPinned,
            baseOpacity: preferences.opacity
        )
        self.panel = panel
        self.preferences = preferences
        self.model = model
        super.init(window: panel)

        panel.contentView = NSHostingView(rootView: FloatingAgentsView(
            model: model,
            onFocus: onFocus,
            onToggleMode: { [weak self] in self?.toggleMode() },
            onLayoutChange: { [weak self] mode in self?.resize(to: mode) },
            onSetPinned: { [weak self] isPinned in self?.setPinned(isPinned) },
            onSetOpacity: { [weak self] opacity in self?.setOpacity(opacity) }
        ))

        // AppKit restores the last frame before placement is validated; clamping
        // immediately prevents a disconnected display from stranding the HUD.
        panel.setFrameAutosaveName("FloatingAgentsPanel")
        clampToVisibleScreens()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clampToVisibleScreens()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    /// Orders the HUD above other apps while preserving the user's active application.
    func show() {
        panel.orderFrontRegardless()
    }

    /// Removes the HUD without destroying the panel retained by this controller.
    func hide() {
        panel.orderOut(nil)
    }

    /// Publishing the snapshot preserves row hover state and relative-text timers.
    func update(snapshot: ActiveAgentsSnapshot) {
        model.snapshot = snapshot
        resize(to: currentEffectiveMode)
    }

    func setPinned(_ isPinned: Bool) {
        model.isPinned = isPinned
        preferences.isPinned = isPinned
    }

    func setOpacity(_ opacity: Double) {
        model.baseOpacity = opacity
        preferences.opacity = opacity
    }

    private var currentEffectiveMode: FloatingPanelMode {
        FloatingPanelLayout.effectiveMode(
            preferred: model.preferredMode,
            isPinned: model.isPinned,
            isHovering: currentMode == .expanded,
            agentCount: model.snapshot.rows.count,
            isDegraded: model.snapshot.status.message != nil
        )
    }

    /// Empty and degraded dots are status indicators rather than navigation, so
    /// clicking them must not overwrite the user's preferred populated mode.
    private func toggleMode() {
        guard !model.snapshot.rows.isEmpty, model.snapshot.status.message == nil else { return }
        let preferredMode: FloatingPanelMode = model.preferredMode == .dot ? .compact : .dot
        model.preferredMode = preferredMode
        preferences.mode = preferredMode
    }

    /// Preserve maxY so hover expansion grows downward and contraction rises upward.
    private func resize(to mode: FloatingPanelMode) {
        currentMode = mode
        let size = FloatingPanelSizing.contentSize(model: model, mode: mode)
        let origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        clampToVisibleScreens()
    }

    /// Revalidating against current visible frames keeps autosaved positions usable
    /// after monitors are removed without changing the content-measured dimensions.
    private func clampToVisibleScreens() {
        let frame = FloatingPanelPlacement.clamp(
            panel.frame,
            into: NSScreen.screens.map(\.visibleFrame)
        )
        panel.setFrame(frame, display: panel.isVisible)
    }
}
