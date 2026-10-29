@testable import AppBundle
import Common
import XCTest

@MainActor
final class NativeFocusFollowTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testFollowingNativeFocusMarksTheWorkspaceLeftBehind() {
        let left = Workspace.get(byName: "follow-left")
        let target = Workspace.get(byName: "follow-target")
        _ = TestWindow.new(id: 9101, parent: left.rootTilingContainer).focusWindow()
        let other = TestWindow.new(id: 9102, parent: target.rootTilingContainer)

        updateFocusCache(other) // macOS focused a window of another workspace

        assertEquals(focus.workspace, target)
        XCTAssertTrue(wasLeftByFollowingNativeFocusRecently(left))
        XCTAssertFalse(wasLeftByFollowingNativeFocusRecently(target))
    }

    func testLeavingWithACommandIsNotFollowingNativeFocus() {
        let left = Workspace.get(byName: "command-left")
        let target = Workspace.get(byName: "command-target")
        _ = TestWindow.new(id: 9201, parent: left.rootTilingContainer).focusWindow()
        TestWindow.new(id: 9202, parent: target.rootTilingContainer)

        XCTAssertTrue(target.focusWorkspace())

        XCTAssertFalse(wasLeftByFollowingNativeFocusRecently(left))
    }
}
