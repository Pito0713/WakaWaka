import AppKit
import SwiftUI

/// Decides how tall the popover has to be.
///
/// This is a type of its own so the rule can be tested against a real
/// `NSPopover`. It used to be a sum of hand-measured constants inside
/// `AppDelegate`, and it went wrong twice — the agents panel was missing from
/// the sum, then the footer's constant was 12pt short — with nothing in the
/// suite able to notice, because measuring `ContentView` in a test says nothing
/// about what `AppDelegate` does with the number.
enum PopoverSizing {
    /// Ask SwiftUI. It already knows, and the `ScrollView`'s own cap on the
    /// approval list comes along for free — which is what keeps the footer on
    /// screen no matter how long the queue gets.
    static func contentHeight(model: PopoverViewModel, width: CGFloat) -> CGFloat {
        NSHostingView(rootView: ContentView(model: model).frame(width: width))
            .fittingSize.height
    }

    static func apply(to popover: NSPopover, model: PopoverViewModel,
                      width: CGFloat, animated: Bool) {
        let target = contentHeight(model: model, width: width)
        guard abs(popover.contentSize.height - target) > 1 else { return }

        guard animated else {
            // First show: size up front so it opens with content already laid
            // out at the right size instead of a blank frame.
            popover.contentSize = NSSize(width: width, height: target)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            popover.contentSize = NSSize(width: width, height: target)
        }
    }
}
