import AppKit

/// The menu bar ghost: pixel maps, skin frames and the animation timer.
extension AppDelegate {
    func setIcon(hasPending: Bool) {
        guard let button = statusItem.button, let iconLayer else { return }
        // A user skin (external PNG frames) wins if active; otherwise the built-in
        // procedural ghost. The pose is fully determined by `idleAction` (the eye
        // direction) which the animation loop drives.
        let skinImage = SkinManager.shared.image(wave: animFrame, action: idleAction.skinName, pending: hasPending)
        let image: NSImage = skinImage ?? makeGhostIcon(hasPending: hasPending, tint: ghostForeground())

        // Keep the status item exactly icon-wide — we no longer set `button.image`,
        // so `variableLength` has nothing to size from; drive the width ourselves.
        let iconSize = image.size                       // points, e.g. 18×18
        let width = iconSize.width.rounded() + 4        // a little breathing room
        if abs(width - lastLength) > 0.5 { statusItem.length = width; lastLength = width }

        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // Center an icon-sized layer inside the button (bounds ≈ status-item width ×
        // menu-bar height). .resizeAspect then fits the frame 1:1 for our square art.
        let b = button.bounds
        let originX = ((b.width  - iconSize.width)  / 2).rounded()
        let originY = ((b.height - iconSize.height) / 2).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // instant swap, never a cross-fade
        iconLayer.contentsScale = scale
        iconLayer.frame = CGRect(x: originX, y: originY, width: iconSize.width, height: iconSize.height)
        // SkinManager returns the *same* cached NSImage for an unchanged frame, so a
        // held pose never re-decodes/re-sets the layer contents.
        if image !== lastIconImage {
            iconLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            lastIconImage = image
        }
        iconLayer.opacity = 1
        CATransaction.commit()

        // Urgency escalation is parked pending a fresh spec — the overlay stays
        // dormant (opacity 0), so pending shows the plain red scanning ghost.
    }

    /// Menu-bar foreground colour for the built-in (no-skin) ghost. The template
    /// auto-tint that a template NSImage gives us does NOT apply to raw CALayer
    /// contents, so we tint the ghost ourselves: white on a dark menu bar, black
    /// on a light one.
    func ghostForeground() -> NSColor {
        let match = statusItem.button?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .white : .black
    }

    // MARK: - Pixel ghost animation

    /// Ghost pixel maps: 0 = transparent, 1 = body (auto dark/light), 2 = eye (transparent cutout)
    /// Two frames alternate the bottom wave → classic Pac-Man ghost float
    enum IdleAction {
        case normal, blink, lookLeft, lookUp, lookDown   // normal = looking right (idle pose)

        /// Stable identifier used to pick a skin frame file.
        var skinName: String {
            switch self {
            case .normal:    return "normal"
            case .blink:     return "blink"
            case .lookLeft:  return "lookLeft"
            case .lookUp:    return "lookUp"
            case .lookDown:  return "lookDown"
            }
        }
    }

    // Classic retro ghost — hand-drawn 9×10 pixel map (user's design + a rounded
    // top row). Chunky on purpose. 0 = empty, 1 = body, 2 = cut-out (eye/mouth).
    static let ghostCols = 9
    static let ghostRows = 10

    func getGhostPixels(wave: Int, action: IdleAction, frightened: Bool = false) -> [[Int]] {
        var base = [
            [0,0,1,1,1,1,1,0,0],   // rounded top
            [0,1,1,1,1,1,1,1,0],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
        ]

        // Feet wave — two alternating frames.
        if wave == 0 {
            base[8] = [1,1,0,1,1,0,1,1,0]
            base[9] = [1,0,0,1,0,0,1,0,0]
        } else {
            base[8] = [1,0,1,1,0,1,1,0,1]
            base[9] = [0,0,1,0,0,1,0,0,1]
        }

        // Pending: frightened face — small eyes + a small wavy mouth, outer columns
        // kept solid so the silhouette never fragments at this coarse size.
        if frightened {
            base[3] = [1,1,2,1,1,1,2,1,1]
            base[4] = [1,1,2,1,1,1,2,1,1]
            base[6] = [1,1,2,1,2,1,2,1,1]
            return base
        }

        // Normal (= looking right) + idle expressions.
        switch action {
        case .normal:                              // idle: pupils to the right
            base[3] = [1,1,2,2,1,1,1,2,2]
            base[4] = [1,1,2,2,1,1,1,2,2]
        case .lookLeft:
            base[3] = [2,2,1,1,1,2,2,1,1]
            base[4] = [2,2,1,1,1,2,2,1,1]
        case .lookUp:                              // eyes higher
            base[2] = [1,2,2,1,1,1,2,2,1]
            base[3] = [1,2,2,1,1,1,2,2,1]
        case .lookDown:                            // eyes lower
            base[4] = [1,2,2,1,1,1,2,2,1]
            base[5] = [1,2,2,1,1,1,2,2,1]
        case .blink:                               // eyes as a thin closed line
            base[4] = [1,2,2,1,1,1,2,2,1]
        }
        return base
    }


    func updateIconAnimationSpeed(hasPending: Bool) {
        let newSpeed: TimeInterval = hasPending ? 0.25 : 0.5
        if newSpeed != currentAnimSpeed || iconTimer == nil {
            iconTimer?.invalidate()
            currentAnimSpeed = newSpeed
            let t = Timer(timeInterval: newSpeed, repeats: true) { [weak self] _ in
                guard let self else { return }

                let currentPending = !self.pendingQueue.isEmpty

                // Reduce Motion: hold a still ghost looking right — no wave, no scan.
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self.animFrame = 0
                    self.idleAction = .normal
                    self.idleActionTicks = 0
                    self.setIcon(hasPending: currentPending)
                    if currentPending != hasPending {
                        self.updateIconAnimationSpeed(hasPending: currentPending)
                    }
                    return
                }

                // Feet glide one step every tick (seamless conveyor over 5 phases).
                if self.waveEnabled { self.animFrame = (self.animFrame + 1) % self.feetPhaseCount }

                if currentPending {
                    // Eyes scan a continuous loop: right → left → up → down.
                    self.idleActionTicks = 0
                    self.scanTick += 1
                    let scan: [IdleAction] = [.normal, .lookLeft, .lookUp, .lookDown]
                    let ticksPerDirection = 4    // ~1.0s each at the pending cadence
                    self.idleAction = scan[(self.scanTick / ticksPerDirection) % scan.count]
                } else {
                    // Idle: look right, blink occasionally.
                    self.scanTick = 0
                    if self.idleActionTicks > 0 {
                        self.idleActionTicks -= 1
                        if self.idleActionTicks == 0 { self.idleAction = .normal }
                    } else if Int.random(in: 0..<100) < 6 {
                        self.idleAction = .blink
                        self.idleActionTicks = 1
                    } else {
                        self.idleAction = .normal
                    }
                }

                self.setIcon(hasPending: currentPending)
                if currentPending != hasPending {
                    self.updateIconAnimationSpeed(hasPending: currentPending)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            iconTimer = t
        }
    }

    func makeGhostIcon(hasPending: Bool, tint: NSColor) -> NSImage {
        // Uniform 13.5×15 pt (px 1.5). To stay crisp on a 1x (non-Retina) screen —
        // where 1.5-pt cells would otherwise straddle half a device pixel and blur —
        // every cell edge is snapped to the *actual* device-pixel grid at draw time
        // (see `snap`). On Retina (2x) the 1.5-pt cells already align, so snapping is
        // a no-op and the even chunky look is preserved; on 1x the cells snap to whole
        // pixels (slightly uneven, but sharp instead of fuzzy).
        let screenScale = statusItem.button?.window?.backingScaleFactor
                        ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let px: CGFloat  = 1.5
        let cols         = Self.ghostCols   // 9
        let rows         = Self.ghostRows   // 10
        let canvasW      = CGFloat(cols) * px  // 13.5 pt
        let canvasH: CGFloat = 22
        let offsetY      = (canvasH - CGFloat(rows) * px) / 2
        let pixels       = getGhostPixels(wave: animFrame, action: idleAction, frightened: hasPending)
        let canvas       = NSSize(width: canvasW, height: canvasH)

        // Tinted directly (not a template image): the caller passes the menu-bar
        // foreground colour, because raw CALayer contents don't get the system's
        // template auto-tint. Pending state is signalled purely by the frightened
        // face (and the faster wave animation).
        let img = NSImage(size: canvas, flipped: false) { _ in
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.setShouldAntialias(false)                      // hard pixel edges
            let s = max(abs(ctx?.ctm.a ?? screenScale), 1)      // real device scale
            func snap(_ v: CGFloat) -> CGFloat { (v * s).rounded() / s }
            tint.setFill()
            for row in 0..<rows {
                for col in 0..<cols where pixels[row][col] == 1 {
                    let x0 = snap(CGFloat(col) * px)
                    let x1 = snap(CGFloat(col + 1) * px)
                    let y0 = snap(offsetY + CGFloat(rows - 1 - row) * px)  // row 0 = top
                    let y1 = snap(offsetY + CGFloat(rows - row) * px)
                    NSBezierPath(rect: NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)).fill()
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
