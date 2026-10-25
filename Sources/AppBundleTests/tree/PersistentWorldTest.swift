@testable import AppBundle
import Common
import XCTest

@MainActor
final class PersistentWorldTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private let app = FrozenApp(pid: 0, bundleId: "bobko.AeroSpace.test-app", launchTime: nil)
    private var monitor: FrozenMonitor { FrozenMonitor(topLeftCorner: mainMonitor.rect.topLeftCorner, visibleWorkspace: "b") }

    private func window(_ id: UInt32, app: FrozenApp? = nil) -> FrozenTreeNode {
        .window(FrozenWindow(id: id, weight: 1, app: app ?? self.app))
    }

    private func workspace(
        _ name: String,
        _ root: FrozenContainer,
        floating: [UInt32] = [],
        mru: UInt32? = nil,
    ) -> FrozenWorkspace {
        FrozenWorkspace(
            name: name,
            monitor: monitor,
            rootTilingNode: root,
            floatingWindows: floating.map { FrozenWindow(id: $0, weight: 1, app: app) },
            macosUnconventionalWindows: [],
            mostRecentWindowId: mru,
        )
    }

    /// Window.get(byId:) can't find windows of a detached tree
    private func testWindow(_ frozen: FrozenWindow) -> Window? {
        TestApp.shared.windows.first { $0.windowId == frozen.id }
    }

    private func container(_ layout: Layout, _ orientation: Orientation, _ children: [FrozenTreeNode]) -> FrozenContainer {
        FrozenContainer(children: children, layout: layout, orientation: orientation, weight: 1)
    }

    func testCaptureEncodeDecodeRoundTrip() {
        let a = Workspace.get(byName: "a").apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
            TestWindow.new(id: 4, parent: $0.floatingWindowsContainer)
        }
        assertEquals(a.focusWorkspace(), true)

        let snapshot = FrozenWorld.capture()
        let workspace = snapshot.workspaces.first { $0.name == "a" }
        assertEquals(workspace?.rootTilingNode.allWindowsRecursive.map(\.id), [1, 2, 3])
        assertEquals(workspace?.floatingWindows.map(\.id), [4])
        assertEquals(workspace?.rootTilingNode.allWindowsRecursive.first?.app, app)
        assertEquals(snapshot.focusedWorkspace, "a")

        assertEquals(PersistentWorld.decode(PersistentWorld.encode(snapshot)), snapshot)
    }

    func testDecodingRejectsOtherFormatVersions() {
        var snapshot = FrozenWorld(workspaces: [], monitors: [], focusedWorkspace: "a")
        snapshot.formatVersion = FrozenWorld.currentFormatVersion + 1
        XCTAssertNil(PersistentWorld.decode(PersistentWorld.encode(snapshot)))
        XCTAssertNil(PersistentWorld.decode(Data("garbage".utf8)))
    }

    func testValidationDropsWindowsOfOtherProcesses() {
        let dead = FrozenApp(pid: 42, bundleId: "dead", launchTime: nil)
        let snapshot = FrozenWorld(
            focusedWorkspace: "a",
            focusedWindowId: 1,
            monitors: [monitor],
            workspaces: [
                FrozenWorkspace(
                    name: "a",
                    monitor: monitor,
                    rootTilingNode: container(.tiles, .h, [window(1), window(2, app: dead), .container(container(.tiles, .v, [window(3, app: dead)]))]),
                    floatingWindows: [FrozenWindow(id: 4, weight: 1, app: dead), FrozenWindow(id: 5, weight: 1, app: app)],
                    macosUnconventionalWindows: [FrozenWindow(id: 6, weight: 1, app: nil)],
                    mostRecentWindowId: 1,
                ),
            ],
        )

        let validated = snapshot.filterWindows { $0.app == self.app }

        assertEquals(validated.allWindows.map(\.id), [1, 5])
        // Empty containers are left to normalization
        assertEquals(validated.workspaces.first?.rootTilingNode.children.count, 2)
    }

    func testRestorePutsPiledUpWindowsBackIntoTheirTrees() async throws {
        // Startup put everything into the focused workspace
        let pile = Workspace.get(byName: "pile").apply {
            for id: UInt32 in 1 ... 6 {
                TestWindow.new(id: id, parent: $0.rootTilingContainer)
            }
        }
        assertEquals(pile.focusWorkspace(), true)
        let snapshot = FrozenWorld(
            focusedWorkspace: "b",
            focusedWindowId: 5,
            monitors: [monitor],
            workspaces: [
                workspace("a", container(.tiles, .h, [window(3), .container(container(.accordion, .v, [window(1), window(2)]))]), floating: [4], mru: 2),
                workspace("b", container(.tiles, .v, [window(5)])),
            ],
        )

        try await snapshot.restore(restoreFocus: true, window: testWindow)

        assertEquals(Workspace.get(byName: "a").rootTilingContainer.layoutDescription, .h_tiles([.window(3), .v_accordion([.window(1), .window(2)])]))
        assertEquals(Workspace.get(byName: "a").floatingWindows.map(\.windowId), [4])
        assertEquals(Workspace.get(byName: "a").mostRecentWindowRecursive?.windowId, 2)
        assertEquals(Workspace.get(byName: "b").rootTilingContainer.layoutDescription, .v_tiles([.window(5)]))
        // Not in the snapshot: stays where it was
        assertEquals(pile.rootTilingContainer.layoutDescription, .h_tiles([.window(6)]))
        assertEquals(focus.workspace.name, "b")
        assertEquals(focus.windowOrNil?.windowId, 5)
        assertEquals(mainMonitor.activeWorkspace.name, "b")
    }

    func testRestoreSkipsWindowsThatAreGone() async throws {
        let a = Workspace.get(byName: "a").apply {
            TestWindow.new(id: 3, parent: $0.rootTilingContainer)
            TestWindow.new(id: 2, parent: $0.rootTilingContainer)
            TestWindow.new(id: 1, parent: $0.rootTilingContainer)
        }
        assertEquals(a.focusWorkspace(), true)
        let snapshot = FrozenWorld(
            focusedWorkspace: "a",
            focusedWindowId: 9,
            monitors: [FrozenMonitor(topLeftCorner: mainMonitor.rect.topLeftCorner, visibleWorkspace: "a")],
            workspaces: [workspace("a", container(.tiles, .v, [window(1), window(9), window(2)]))],
        )

        try await snapshot.restore(restoreFocus: true, window: testWindow)

        // 9 is gone, 3 is unknown to the snapshot and is appended
        assertEquals(a.rootTilingContainer.layoutDescription, .v_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(focus.workspace.name, "a")
    }

    func testRestoresMacosFullscreenWindowsIntoTheirContainer() async throws {
        let pile = Workspace.get(byName: "pile").apply {
            TestWindow.new(id: 1, parent: $0.rootTilingContainer)
        }
        assertEquals(pile.focusWorkspace(), true)
        var fullscreen = FrozenWindow(id: 1, weight: 1, app: app)
        fullscreen.macosParentKind = .macosFullscreenWindowsContainer
        fullscreen.macosPrevParentKind = .tilingContainer
        let world = FrozenWorld(
            workspaces: [
                FrozenWorkspace(
                    name: "a",
                    monitor: monitor,
                    rootTilingNode: container(.tiles, .h, []),
                    floatingWindows: [],
                    macosUnconventionalWindows: [fullscreen],
                    mostRecentWindowId: nil,
                ),
            ],
            monitors: [monitor],
        )

        try await world.restore(restoreFocus: false, window: testWindow)

        let window = try XCTUnwrap(testWindow(fullscreen))
        XCTAssertTrue(window.parent is MacosFullscreenWindowsContainer)
        assertEquals(window.nodeWorkspace?.name, "a")
        assertEquals(window.layoutReason, .macos(prevParentKind: .tilingContainer))
    }

    func testPlacements() {
        let snapshot = FrozenWorld(
            focusedWorkspace: "a",
            focusedWindowId: nil,
            monitors: [monitor],
            workspaces: [workspace("a", container(.tiles, .h, [window(1)]), floating: [2])],
        )
        assertEquals(snapshot.placements[1]?.workspace, "a")
        assertEquals(snapshot.placements[1]?.kind, .tiling)
        assertEquals(snapshot.placements[2]?.kind, .floating)
        XCTAssertNil(snapshot.placements[3])
    }

    /// The format that .release/swap-in-fast-detect.sh writes for the transition from builds without a persistent world
    func testDecodesHandWrittenSnapshot() {
        let json = """
            {
              "formatVersion": 1,
              "focusedWorkspace": "2",
              "focusedWindowId": 7,
              "monitors": [{"topLeftCorner": [0, 0], "visibleWorkspace": "2"}],
              "workspaces": [{
                "name": "2",
                "monitor": {"topLeftCorner": [0, 0], "visibleWorkspace": "2"},
                "rootTilingNode": {"layout": "tiles", "orientation": "h", "weight": 1, "children": [
                  {"window": {"id": 7, "weight": 1, "app": {"pid": 123, "bundleId": "io.yeyito.st"}}}
                ]},
                "floatingWindows": [{"id": 8, "weight": 1, "app": {"pid": 124, "bundleId": null}}],
                "macosUnconventionalWindows": [{"id": 9, "weight": 1, "app": {"pid": 125, "bundleId": "org.mozilla.firefox"},
                                                "macosParentKind": "macosFullscreenWindowsContainer"}]
              }]
            }
            """
        let snapshot = PersistentWorld.decode(Data(json.utf8))
        assertEquals(snapshot?.allWindows.map(\.id), [7, 8, 9])
        assertEquals(snapshot?.allWindows.first?.app, FrozenApp(pid: 123, bundleId: "io.yeyito.st", launchTime: nil))
        assertEquals(snapshot?.workspaces.first?.rootTilingNode.orientation, .h)
        assertEquals(snapshot?.workspaces.first?.macosUnconventionalWindows.first?.macosParentKind, .macosFullscreenWindowsContainer)
        assertEquals(snapshot?.monitors.first?.topLeftCorner, .zero)
    }
}

extension FrozenWorld {
    init(focusedWorkspace: String, focusedWindowId: UInt32?, monitors: [FrozenMonitor], workspaces: [FrozenWorkspace]) {
        self.init(workspaces: workspaces, monitors: monitors, focusedWorkspace: focusedWorkspace, focusedWindowId: focusedWindowId)
    }
}
