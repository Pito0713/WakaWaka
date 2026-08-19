import AppKit

enum FloatingPanelLayout {
    /// The HUD has exactly one form: the full detail list. Resizing under the
    /// cursor moved the very rows the user was aiming at, so hover expansion and
    /// the collapsed dot are both gone — the close control replaces the dot.
    static let width: CGFloat = 300

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
