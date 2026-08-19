import AppKit
import SwiftUI

enum FloatingPanelSizing {
    /// SwiftUI must supply the height because font metrics and conditional rows
    /// are the source of truth; duplicating them as constants has clipped UI before.
    @MainActor
    static func contentSize(model: FloatingPanelModel) -> NSSize {
        let width = FloatingPanelLayout.width
        // Measuring against a copy keeps the throwaway hosting view from attaching
        // a second observer to the live model. The copy must carry focusError:
        // that conditional row changes the height.
        let measurementModel = FloatingPanelModel(
            snapshot: model.snapshot,
            baseOpacity: model.baseOpacity,
            focusError: model.focusError
        )
        let rootView = FloatingAgentsView(model: measurementModel, onFocus: { _ in })
        let height = NSHostingView(rootView: rootView.frame(width: width)).fittingSize.height
        return NSSize(width: width, height: height)
    }
}
