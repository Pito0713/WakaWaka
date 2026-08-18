import AppKit

enum FloatingPanelMode: String, Codable, CaseIterable {
    case dot
    case compact
    case expanded
}

enum FloatingPanelLayout {
    /// Failure and absence outrank interaction state: degraded data must collapse
    /// to a visible warning dot regardless of saved mode, pinning, or hover, or
    /// stale UI could masquerade as trustworthy registry data. Only a healthy,
    /// populated panel may honor hover before falling back to the saved preference.
    static func effectiveMode(
        preferred: FloatingPanelMode,
        isPinned: Bool,
        isHovering: Bool,
        agentCount: Int,
        isDegraded: Bool
    ) -> FloatingPanelMode {
        if isDegraded {
            return .dot
        }
        if agentCount == 0 {
            return .dot
        }
        if !isPinned && isHovering {
            return .expanded
        }
        return preferred
    }

    static func opacity(agentCount: Int, isDegraded: Bool, base: Double) -> Double {
        // Preserve the user's base opacity when registry access fails: unreadable
        // state needs more attention than a healthy registry with no agents.
        if isDegraded {
            return base
        }
        if agentCount == 0 {
            return 0.35
        }
        return base
    }

    /// Only width is policy here. Height must be measured from the hosted SwiftUI
    /// content because hand-summed constants have already clipped real sections.
    static func width(for mode: FloatingPanelMode) -> CGFloat {
        switch mode {
        case .dot:
            return 30
        case .compact:
            return 220
        case .expanded:
            return 300
        }
    }
}

enum FloatingPanelPlacement {
    /// Screen frames are injected instead of read from `NSScreen.screens` so this
    /// stays a pure geometry operation and multi-display or no-display cases remain
    /// deterministic in tests.
    static func clamp(
        _ frame: NSRect,
        into screens: [NSRect],
        minVisible: CGFloat = 40
    ) -> NSRect {
        guard let primaryScreen = screens.first else {
            return frame
        }

        let requiredVisibleLength = max(0, minVisible)
        let isVisible = screens.contains { screen in
            let intersection = frame.intersection(screen)
            return intersection.width >= requiredVisibleLength
                && intersection.height >= requiredVisibleLength
        }
        if isVisible {
            return frame
        }

        let originX: CGFloat
        if frame.width > primaryScreen.width {
            originX = primaryScreen.minX
        } else {
            originX = min(max(frame.minX, primaryScreen.minX), primaryScreen.maxX - frame.width)
        }

        let originY: CGFloat
        if frame.height > primaryScreen.height {
            originY = primaryScreen.maxY - frame.height
        } else {
            originY = min(max(frame.minY, primaryScreen.minY), primaryScreen.maxY - frame.height)
        }

        // Move only the origin: resizing would discard the content-measured size
        // and silently change the HUD layout when displays change.
        return NSRect(origin: NSPoint(x: originX, y: originY), size: frame.size)
    }
}
