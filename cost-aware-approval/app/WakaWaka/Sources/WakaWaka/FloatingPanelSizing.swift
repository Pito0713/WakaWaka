import AppKit
import SwiftUI

enum FloatingPanelSizing {
    /// SwiftUI must supply the height because font metrics and conditional rows
    /// are the source of truth; duplicating them as constants has clipped UI before.
    @MainActor
    static func contentSize(
        model: FloatingPanelModel,
        mode: FloatingPanelMode
    ) -> NSSize {
        let width = FloatingPanelLayout.width(for: mode)
        // Pinning locks measurement to the requested mode, so fresh hover state
        // cannot pair one mode's width with another mode's height. The copy must
        // also carry focusError because that conditional row changes the height.
        let measurementModel = FloatingPanelModel(
            snapshot: model.snapshot,
            preferredMode: mode,
            isPinned: true,
            baseOpacity: model.baseOpacity,
            focusError: model.focusError
        )
        let rootView = FloatingAgentsView(
            model: measurementModel,
            onFocus: { _ in },
            onToggleMode: {},
            onLayoutChange: { _ in }
        )
        let height = NSHostingView(rootView: rootView.frame(width: width)).fittingSize.height
        return NSSize(width: width, height: height)
    }
}
