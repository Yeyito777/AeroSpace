@testable import AppBundle
import Common
import XCTest

@MainActor
final class HorizontalTilingOnlyTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.horizontalTilingOnly = true
    }

    func testParse() {
        let result = parseConfig("horizontal-tiling-only = true")
        assertEquals(result.errors, [])
        assertEquals(result.config.horizontalTilingOnly, true)
    }

    func testVerticalRootBecomesHorizontal() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.changeOrientation(.v)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testNestedContainersAreFlattenedInOrder() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 2).apply {
                TestWindow.new(id: 2, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 3, parent: $0)
                }
            }
            TestWindow.new(id: 4, parent: $0)
        }
        workspace.normalizeContainers()
        let root = workspace.rootTilingContainer
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3), .window(4)]))
        assertEquals(root.children.map { $0.getWeight(.h) }, [1, 1, 1, 1])
    }

    func testMoveUpDoesNotTileVertically() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
            TestWindow.new(id: 3, parent: $0)
        }
        await parseCommand("move up").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.orientation, .h)
        assertEquals(workspace.rootTilingContainer.children.count, 3)
        assertEquals(workspace.rootTilingContainer.children.allSatisfy { $0 is Window }, true)
        assertEquals(focus.windowOrNil?.windowId, 2)
    }

    func testLayoutVerticalIsUndone() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }
        await parseCommand("layout v_tiles").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }
}
