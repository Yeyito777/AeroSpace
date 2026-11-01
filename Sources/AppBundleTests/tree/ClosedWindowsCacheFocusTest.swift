@testable import AppBundle
import Common
import XCTest

/// Closing a window (e.g. Roblox) that its app takes a moment to close: a refresh meanwhile registers it again, as a
/// new window. That used to restore a minutes old closed windows cache, including the workspace that was visible back
/// then, while the keyboard focus stayed on the current one
@MainActor
final class ClosedWindowsCacheFocusTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetClosedWindowsCache()
    }

    override func tearDown() async throws { resetClosedWindowsCache() }

    /// The cache is captured while workspace "b" is visible, then the user goes to "a"
    private func setUpStaleCache() -> (a: Workspace, closing: Window) {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        let closing = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        TestWindow.new(id: 3, parent: a.rootTilingContainer)
        XCTAssertTrue(TestWindow.new(id: 2, parent: b.rootTilingContainer).focusWindow())
        cacheClosedWindowIfNeeded()
        XCTAssertTrue(closing.focusWindow())
        assertEquals(focus.workspace, a)
        XCTAssertTrue(a.isVisible)
        return (a, closing)
    }

    func testRestoringTheCacheKeepsTheFocusedWorkspaceOnScreen() async throws {
        let (a, closing) = setUpStaleCache()

        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: closing)
        XCTAssertTrue(restored)

        assertEquals(focus.workspace, a)
        XCTAssertTrue(a.isVisible)
    }

    func testWindowClosedOnPurposeDoesNotRestoreTheCache() async throws {
        let (a, closing) = setUpStaleCache()

        forgetClosedWindowInClosedWindowsCache(closing.windowId) // What garbageCollect does for the close command

        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: closing)
        XCTAssertFalse(restored)
        XCTAssertTrue(a.isVisible)
    }
}
