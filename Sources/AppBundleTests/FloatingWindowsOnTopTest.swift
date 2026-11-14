@testable import AppBundle
import Common
import XCTest

@MainActor
final class FloatingWindowsOnTopTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func w(_ id: UInt32, _ x: CGFloat, _ width: CGFloat) -> StackedWindow {
        StackedWindow(windowId: id, frame: CGRect(x: x, y: 0, width: width, height: 100))
    }

    func testParse() {
        let result = parseConfig("floating-windows-on-top = true")
        assertEquals(result.errors, [])
        assertEquals(result.config.floatingWindowsOnTop, true)
    }

    func testNothingToRaiseWhenFloatingWindowsAreInFront() {
        let stack = [w(10, 50, 100), w(1, 0, 100), w(2, 100, 100)]
        assertEquals(floatingWindowsToRaise(stack: stack, floating: [10], tiling: [1, 2]), [])
    }

    func testCoveredFloatingWindowIsRaised() {
        let stack = [w(1, 0, 100), w(10, 50, 100), w(2, 100, 100)]
        assertEquals(floatingWindowsToRaise(stack: stack, floating: [10], tiling: [1, 2]), [10])
    }

    func testTilingWindowThatDoesntOverlapIsIgnored() {
        // Touching edges isn't an overlap
        let stack = [w(1, 0, 100), w(10, 100, 50)]
        assertEquals(floatingWindowsToRaise(stack: stack, floating: [10], tiling: [1]), [])
    }

    func testFloatingWindowsInFrontOfTheCoveredOneAreRaisedAfterItKeepingTheirOrder() {
        let stack = [w(11, 0, 50), w(1, 0, 100), w(12, 20, 50), w(10, 50, 100), w(13, 500, 50)]
        assertEquals(floatingWindowsToRaise(stack: stack, floating: [10, 11, 12, 13], tiling: [1]), [10, 12, 11])
    }

    func testOtherWindowsAreIgnored() {
        // E.g. a window of an app AeroSpace doesn't manage
        let stack = [w(99, 0, 1000), w(10, 50, 100), w(1, 0, 100)]
        assertEquals(floatingWindowsToRaise(stack: stack, floating: [10], tiling: [1]), [])
    }
}
