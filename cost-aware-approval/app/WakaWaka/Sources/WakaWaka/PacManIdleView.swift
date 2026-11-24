import SwiftUI

// MARK: - Ghost idle animation (mirrors menu bar icon, same pixel size)

/// Idle-state animation: Pac-Man chomps rightward along a pellet trail with a
/// ghost chasing behind. Eating the flashing power pellet flips the ghost to a
/// blue "frightened" face that falls back (flees). Everything is a pure function
/// of `frame` so the loop stays deterministic; motion is frozen when the system
/// "Reduce Motion" accessibility setting is on.
struct PacManIdleView: View {
    let isAnimating: Bool
    @State private var frame = 0
    private let timer = Timer.publish(every: 0.14, on: .main, in: .common).autoconnect()

    // ── Pixel maps (1 = body, 0 = empty, 2 = cut-out that shows the background) ──
    private static let pacClosed: [[Int]] = [
        [0,0,1,1,1,1,1,0,0],
        [0,1,1,1,1,1,1,1,0],
        [1,1,1,1,1,1,1,1,1],
        [1,1,1,1,1,1,1,1,1],
        [1,1,1,1,1,1,1,1,1],
        [1,1,1,1,1,1,1,1,1],
        [1,1,1,1,1,1,1,1,1],
        [0,1,1,1,1,1,1,1,0],
        [0,0,1,1,1,1,1,0,0],
    ]
    private static let pacOpen: [[Int]] = [   // wedge mouth, facing right
        [0,0,1,1,1,1,1,0,0],
        [0,1,1,1,1,1,1,1,0],
        [1,1,1,1,1,1,0,0,0],
        [1,1,1,1,1,0,0,0,0],
        [1,1,1,1,0,0,0,0,0],
        [1,1,1,1,1,0,0,0,0],
        [1,1,1,1,1,1,0,0,0],
        [0,1,1,1,1,1,1,1,0],
        [0,0,1,1,1,1,1,0,0],
    ]
    private static let ghostEyes: [[Int]] = [   // eaten ghost — just the eyes, retreating
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
        [0,1,1,0,0,0,1,1,0],
        [0,1,1,0,0,0,1,1,0],
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0],
    ]
    // Ghost — two bottom-wave frames; face swapped for the frightened variant.
    private static func ghost(wave: Int, frightened: Bool) -> [[Int]] {
        var g: [[Int]] = [
            [0,0,1,1,1,1,1,0,0],
            [0,1,1,1,1,1,1,1,0],
            [1,1,1,1,1,1,1,1,1],
            [1,2,2,1,1,1,2,2,1],
            [1,2,2,1,1,1,2,2,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,1,1,1,1,1,1,1],
            [1,1,0,1,1,0,1,1,0],
            [1,0,0,1,0,0,1,0,0],
        ]
        if wave == 1 {
            g[8] = [1,0,1,1,0,1,1,0,1]
            g[9] = [0,0,1,0,0,1,0,0,1]
        }
        if frightened {   // small dot eyes + zig-zag mouth
            g[3] = [1,1,2,1,1,1,2,1,1]
            g[4] = [1,1,2,1,1,1,2,1,1]
            g[6] = [1,2,1,2,1,2,1,2,1]
            g[7] = [1,1,2,1,2,1,2,1,1]
        }
        return g
    }

    // ── Scene geometry (measured in pixel cells; multiplied by `px`) ──
    private static let px: CGFloat        = 2.0   // integer → crisp at 1x and 2x
    private static let canvasCols: CGFloat = 80
    private static let pelletCols: [CGFloat] = [14, 24, 34, 44, 54, 64]
    private static let powerIndex          = 3          // pelletCols[3] is the power pellet
    private static let ghostGap: CGFloat   = 14         // cells Pac leads the ghost by
    private static let pacSpeed: CGFloat   = 1.8        // cells advanced per frame
    private static let pacStart: CGFloat   = -12        // enters from off-screen left
    // Loop length: travel until Pac exits the right edge, then restart.
    private static var loopFrames: Int {
        Int(((canvasCols + 12) - pacStart) / pacSpeed)  // ≈ 57
    }

    var body: some View {
        let px = Self.px
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Freeze on a legible mid-chomp pose when Reduce Motion is on.
        let L = Self.loopFrames
        let f = reduceMotion ? 20 : (frame % L)
        // Every 4th loop is the "hunt" easter egg: the ghost runs ahead in blue and
        // Pac chases it down (→ floating eyes) instead of the usual flee-behind.
        // Deterministic per loop so it stays a rare, repeatable surprise.
        let isHunt = !reduceMotion && (frame / L) % 4 == 3

        let pacX       = Self.pacStart + Self.pacSpeed * CGFloat(f)   // sprite left edge
        let pacCenter  = pacX + 4.5
        let powerCol   = Self.pelletCols[Self.powerIndex]
        // Power window: from eating the power pellet until it wears off.
        let powerWindow: CGFloat = 28
        let powerActive = pacCenter >= powerCol && pacCenter < powerCol + powerWindow
        // Frightened ghost falls back, then smoothly catches back up to the normal
        // chase gap — a triangular profile so `flee` returns to 0 continuously at the
        // window's end instead of snapping the ghost forward.
        let flee: CGFloat = {
            guard powerActive else { return 0 }
            let d = pacCenter - powerCol            // 0 … powerWindow
            let peak: CGFloat = 10                  // furthest-behind point
            let maxFlee: CGFloat = 12
            return d < peak
                ? maxFlee * (d / peak)                                   // falling back
                : maxFlee * max(0, (powerWindow - d) / (powerWindow - peak)) // catching up
        }()
        let ghostBehindX = pacX - Self.ghostGap - flee

        // Hunt-loop geometry: ghost leads, Pac closes the gap; once caught the ghost
        // becomes eyes that outrun Pac to the right and exit.
        let catchCenter: CGFloat = 50
        let ghostAheadX = pacX + max(5, (catchCenter - pacCenter) * 0.4 + 5)
        let eyesX       = (catchCenter - 4.5) + 5 + 4 * (pacCenter - catchCenter)
        let ghostCaught = pacCenter >= catchCenter

        let canvasW = Self.canvasCols * px
        let canvasH = 11 * px

        Canvas { ctx, _ in
            let isDark = NSApp.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bodyColor: Color = isDark ? .white : .black
            let pacColor:  Color = isDark ? Color(red: 1.0,  green: 0.85, blue: 0.20)
                                          : Color(red: 0.82, green: 0.60, blue: 0.0)
            let scaredColor: Color = isDark ? Color(red: 0.45, green: 0.62, blue: 1.0)
                                            : Color(red: 0.15, green: 0.35, blue: 0.9)

            func draw(_ map: [[Int]], atCol ox: CGFloat, rowOffset oy: CGFloat, color: Color) {
                for r in map.indices {
                    for c in map[r].indices where map[r][c] == 1 {
                        let rect = CGRect(
                            x: (ox + CGFloat(c)) * px,
                            y: (oy + CGFloat(r)) * px,
                            width: px, height: px
                        )
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }
            }

            // Pellets — small dots, eaten once Pac's centre passes them.
            let pelletCenterY = 5.0 * px
            for (i, col) in Self.pelletCols.enumerated() {
                guard pacCenter < col else { continue }        // already eaten
                if i == Self.powerIndex {
                    let d = px * 3.2                            // power pellet: bigger, flashing
                    let alpha: CGFloat = (f % 2 == 0) ? 1.0 : 0.3
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: col * px - d/2, y: pelletCenterY - d/2,
                                               width: d, height: d)),
                        with: .color(pacColor.opacity(alpha)))
                } else {
                    let d = px * 1.7
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: col * px - d/2, y: pelletCenterY - d/2,
                                               width: d, height: d)),
                        with: .color(bodyColor.opacity(0.5)))
                }
            }

            // Ghost. Normal loop: chases behind, turning blue while Pac is powered.
            // Hunt loop: flees ahead in blue, then is eaten → floating eyes retreat.
            let wave = f % 2
            if isHunt {
                if ghostCaught {
                    draw(Self.ghostEyes, atCol: eyesX, rowOffset: 0.5, color: bodyColor)
                } else {
                    draw(Self.ghost(wave: wave, frightened: true),
                         atCol: ghostAheadX, rowOffset: 0.5, color: scaredColor)
                }
            } else {
                draw(Self.ghost(wave: wave, frightened: powerActive),
                     atCol: ghostBehindX, rowOffset: 0.5,
                     color: powerActive ? scaredColor : bodyColor)
            }

            // Pac-Man — chomps open/closed, always facing right.
            let pacMap = (f % 2 == 0) ? Self.pacOpen : Self.pacClosed
            draw(pacMap, atCol: pacX, rowOffset: 1.0, color: pacColor)
        }
        .frame(width: canvasW, height: canvasH)
        .onReceive(timer) { _ in
            // Skipping the state change is what stops the redraw; the tick itself is free.
            guard isAnimating, !reduceMotion else { return }
            frame &+= 1
        }
    }
}
