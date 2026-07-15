@testable import AppBundle
import XCTest

final class MacAppFocusTest: XCTestCase {
    func testFreshSingleWindowAppRequiresNativeWindowRaise() {
        XCTAssertFalse(canFocusByActivatingAppOnly(
            lastNativeFocusedWindowId: nil,
            targetWindowId: 42,
        ))
    }

    func testAlreadyNativeFocusedWindowCanUseActivationOnly() {
        XCTAssertTrue(canFocusByActivatingAppOnly(
            lastNativeFocusedWindowId: 42,
            targetWindowId: 42,
        ))
    }

    func testDifferentWindowRequiresNativeWindowRaise() {
        XCTAssertFalse(canFocusByActivatingAppOnly(
            lastNativeFocusedWindowId: 7,
            targetWindowId: 42,
        ))
    }
}
