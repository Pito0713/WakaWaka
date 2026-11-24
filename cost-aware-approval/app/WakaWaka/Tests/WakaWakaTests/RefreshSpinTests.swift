import Testing
import Foundation
@testable import WakaWaka

/// The refresh spin is held to a floor because the work it reports on is
/// faster than one frame. Tying the spin to completion alone left the icon
/// motionless, which reads as a click that was ignored.
@Suite struct RefreshSpinTests {
    @Test func aScanThatReturnsImmediatelyStillSpinsAFullTurn() {
        #expect(RefreshSpin.remaining(after: 0) == RefreshSpin.turnDuration)
    }

    @Test func aFastScanIsToppedUpToOneTurn() {
        let elapsed = 0.05
        #expect(RefreshSpin.remaining(after: elapsed) == RefreshSpin.turnDuration - elapsed)
    }

    @Test func aScanLongerThanOneTurnAddsNoDelay() {
        #expect(RefreshSpin.remaining(after: RefreshSpin.turnDuration + 1) == 0)
        #expect(RefreshSpin.remaining(after: RefreshSpin.turnDuration) == 0)
    }
}

/// The footer spin is computed from elapsed time rather than animated, so it
/// can be paused outright; these pin the angle it draws.
@Suite struct FooterRefreshSpinTests {
    @Test func startsUpright() {
        #expect(PopoverFooter.spinDegrees(elapsed: 0) == 0)
    }

    @Test func turnsHalfwayInHalfATurn() {
        let degrees = PopoverFooter.spinDegrees(elapsed: PopoverFooter.spinTurnDuration / 2)
        #expect(abs(degrees - 180) < 0.001)
    }

    @Test func wrapsInsteadOfGrowingWithoutBound() {
        let degrees = PopoverFooter.spinDegrees(elapsed: PopoverFooter.spinTurnDuration * 10.25)
        #expect(abs(degrees - 90) < 0.001)
    }
}
