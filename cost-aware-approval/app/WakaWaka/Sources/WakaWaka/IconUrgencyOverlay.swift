import AppKit

/// How urgently the menu bar icon should signal pending approvals.
enum IconUrgency {
    case none
    case pending
    case urgent
}

/// Tints the menu bar icon to communicate approval urgency.
///
/// A non-urgent pending approval is left untinted: the skin already signals it
/// with its frightened (blue) frame, and tinting over that just muddies it. Only
/// `.urgent` paints — a near-opaque red masked to the ghost's body, so the blue
/// frightened face reads clearly as "angry red" rather than a murky purple — plus
/// a slow opacity pulse so an about-to-auto-deny approval looks alarmed.
final class IconUrgencyOverlay {
    /// Red tint used when at least one pending approval is urgent.
    private static let urgentColor = NSColor.systemRed
    /// Opacity of the tint layer while `.urgent`. Near-opaque so it overrides the
    /// frightened-blue base into a clean red instead of a muddy blend.
    private static let urgentOpacity: Float = 0.9
    /// Peak-to-trough swing of the urgent pulse, centered on `urgentOpacity`.
    private static let urgentPulseAmplitude: Float = 0.2
    /// One full breathe-in/breathe-out cycle, in seconds.
    private static let urgentPulseDuration: CFTimeInterval = 0.8
    private static let pulseAnimationKey = "urgencyPulse"

    private let tintLayer: CALayer
    private let maskLayer: CALayer
    /// `iconLayer`'s frame changes whenever the rendered icon size changes (skin
    /// swaps, etc.), so we re-sync to it on every `update()`, not just at init.
    private weak var hostLayer: CALayer?

    /// - Parameter host: the icon's CALayer (`iconLayer` on the app delegate). The
    ///   overlay is added as a sublayer immediately and tracks `host`'s frame/scale.
    init(host: CALayer) {
        let mask = CALayer()
        mask.actions = ["contents": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        self.maskLayer = mask

        let tint = CALayer()
        tint.actions = ["opacity": NSNull(), "bounds": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
        tint.mask = mask
        tint.opacity = 0
        self.tintLayer = tint
        self.hostLayer = host

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.contentsScale = host.contentsScale
        mask.contentsScale = host.contentsScale
        tint.frame = host.bounds
        mask.frame = host.bounds
        host.addSublayer(tint)
        CATransaction.commit()
    }

    /// Refreshes the tint color, mask silhouette, and pulse state for `urgency`.
    /// - Parameter silhouette: the icon image currently on screen — its alpha
    ///   channel becomes the mask so the tint stays inside the ghost's body.
    func update(silhouette: NSImage, urgency: IconUrgency) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let host = hostLayer {
            tintLayer.contentsScale = host.contentsScale
            maskLayer.contentsScale = host.contentsScale
            tintLayer.frame = host.bounds
            maskLayer.frame = host.bounds
        }
        maskLayer.contents = silhouette.cgImage(forProposedRect: nil, context: nil, hints: nil)

        switch urgency {
        case .none, .pending:
            // No tint: a non-urgent pending is already signalled by the skin's
            // frightened (blue) frame — overlaying colour on it only muddies it.
            tintLayer.opacity = 0
            tintLayer.backgroundColor = nil
        case .urgent:
            tintLayer.backgroundColor = Self.urgentColor.cgColor
            tintLayer.opacity = Self.urgentOpacity
        }
        CATransaction.commit()

        updatePulse(for: urgency)
    }

    /// Adds or removes the urgent breathing animation, honoring Reduce Motion.
    private func updatePulse(for urgency: IconUrgency) {
        guard urgency == .urgent, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            tintLayer.removeAnimation(forKey: Self.pulseAnimationKey)
            return
        }
        guard tintLayer.animation(forKey: Self.pulseAnimationKey) == nil else { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = Self.urgentOpacity - Self.urgentPulseAmplitude / 2
        pulse.toValue = Self.urgentOpacity + Self.urgentPulseAmplitude / 2
        pulse.duration = Self.urgentPulseDuration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        tintLayer.add(pulse, forKey: Self.pulseAnimationKey)
    }

    /// Derives urgency from the current pending queue. Pure function so the
    /// caller can compute it from `pendingQueue` without touching layer state.
    static func urgency(pendingCount: Int, hasUrgent: Bool) -> IconUrgency {
        if pendingCount == 0 { return .none }
        return hasUrgent ? .urgent : .pending
    }
}
