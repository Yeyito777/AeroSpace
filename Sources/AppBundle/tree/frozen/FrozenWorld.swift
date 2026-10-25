import AppKit
import Common

/// A copy of the "entire world": workspace trees, monitors and focus. Restored by:
/// - closedWindowsCache: when windows that the lock screen made unobservable come back
/// - persistentWorld: after an AeroSpace restart
struct FrozenWorld: Sendable, Codable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int = currentFormatVersion
    let workspaces: [FrozenWorkspace]
    let monitors: [FrozenMonitor]
    var focusedWorkspace: String? = nil
    var focusedWindowId: UInt32? = nil

    static let empty = FrozenWorld(workspaces: [], monitors: [])

    @MainActor static func capture() -> FrozenWorld {
        FrozenWorld(
            workspaces: Workspace.all.map(FrozenWorkspace.init),
            monitors: AppBundle.monitors.map(FrozenMonitor.init),
            focusedWorkspace: focus.workspace.name,
            focusedWindowId: focus.windowOrNil?.windowId,
        )
    }

    var allWindows: [FrozenWindow] {
        workspaces.flatMap { $0.rootTilingNode.allWindowsRecursive + $0.floatingWindows + $0.macosUnconventionalWindows }
    }

    var windowIds: Set<UInt32> { allWindows.map(\.id).toSet() }

    /// Drops windows for which `isIncluded` returns false. Empty containers are left to normalization
    func filterWindows(_ isIncluded: (FrozenWindow) -> Bool) -> FrozenWorld {
        FrozenWorld(
            formatVersion: formatVersion,
            workspaces: workspaces.map { workspace in
                FrozenWorkspace(
                    name: workspace.name,
                    monitor: workspace.monitor,
                    rootTilingNode: workspace.rootTilingNode.filterWindows(isIncluded),
                    floatingWindows: workspace.floatingWindows.filter(isIncluded),
                    macosUnconventionalWindows: workspace.macosUnconventionalWindows.filter(isIncluded),
                    mostRecentWindowId: workspace.mostRecentWindowId,
                )
            },
            monitors: monitors,
            focusedWorkspace: focusedWorkspace,
            focusedWindowId: focusedWindowId,
        )
    }

    /// Puts the windows that `lookup` finds back into their trees and workspaces, and restores monitors (and focus).
    /// Windows that can't be found are skipped. Windows that the world doesn't know stay in their workspaces
    @MainActor func restore(restoreFocus: Bool, window lookup: (FrozenWindow) -> Window?) async throws {
        for frozenWorkspace in workspaces {
            let workspace = Workspace.get(byName: frozenWorkspace.name)
            for frozen in frozenWorkspace.floatingWindows {
                guard let window = lookup(frozen) else { continue }
                window.layoutReason = .standard
                window.bindAsFloatingWindow(to: workspace)
                restoreHiddenInCorner(window, frozen)
            }
            for frozen in frozenWorkspace.macosUnconventionalWindows {
                guard let window = lookup(frozen) else { continue }
                bindMacosUnconventionalWindow(window, frozen, workspace)
                restoreHiddenInCorner(window, frozen)
            }

            let prevRoot = workspace.rootTilingContainer // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
            let potentialOrphans = prevRoot.allLeafWindowsRecursive
            prevRoot.unbindFromParent()
            restoreTreeRecursive(frozenWorkspace.rootTilingNode, parent: workspace, index: INDEX_BIND_LAST, lookup)
            for window in potentialOrphans where window.nodeWorkspace == nil {
                try await window.relayoutWindow(on: workspace, .cancellable, forceTile: true)
            }

            if let mru = frozenWorkspace.mostRecentWindowId.flatMap(window(byId:)).flatMap(lookup), mru.nodeWorkspace == workspace {
                mru.markAsMostRecentChild()
            }
        }
        restoreMonitors()

        if restoreFocus, let focusedWorkspace {
            let focusedWindow = focusedWindowId.flatMap(window(byId:)).flatMap(lookup)
            if let focusedWindow, focusedWindow.nodeWorkspace?.name == focusedWorkspace {
                _ = focusedWindow.focusWindow()
            } else {
                _ = Workspace.get(byName: focusedWorkspace).focusWorkspace()
            }
        }
    }

    @MainActor func restoreMonitors() {
        let topLeftCornerToMonitor = AppBundle.monitors.grouped { $0.rect.topLeftCorner }
        // Workspaces remember their monitor (assignedMonitorPoint) when they become visible on it
        for frozenWorkspace in workspaces {
            _ = topLeftCornerToMonitor[frozenWorkspace.monitor.topLeftCorner]?
                .singleOrNil()?
                .setActiveWorkspace(Workspace.get(byName: frozenWorkspace.name))
        }
        for monitor in monitors {
            _ = topLeftCornerToMonitor[monitor.topLeftCorner]?
                .singleOrNil()?
                .setActiveWorkspace(Workspace.get(byName: monitor.visibleWorkspace))
        }
    }

    private func window(byId id: UInt32) -> FrozenWindow? { allWindows.first { $0.id == id } }
}

struct FrozenMonitor: Sendable, Codable, Equatable {
    let topLeftCorner: CGPoint
    let visibleWorkspace: String

    @MainActor init(_ monitor: Monitor) {
        topLeftCorner = monitor.rect.topLeftCorner
        visibleWorkspace = monitor.activeWorkspace.name
    }

    init(topLeftCorner: CGPoint, visibleWorkspace: String) {
        self.topLeftCorner = topLeftCorner
        self.visibleWorkspace = visibleWorkspace
    }
}

struct FrozenWorkspace: Sendable, Codable, Equatable {
    let name: String
    let monitor: FrozenMonitor // todo drop this property, once monitor to workspace assignment migrates to TreeNode
    let rootTilingNode: FrozenContainer
    let floatingWindows: [FrozenWindow]
    let macosUnconventionalWindows: [FrozenWindow]
    /// The window that gets focus when the workspace is focused
    var mostRecentWindowId: UInt32? = nil

    @MainActor init(_ workspace: Workspace) {
        name = workspace.name
        monitor = FrozenMonitor(workspace.workspaceMonitor)
        rootTilingNode = FrozenContainer(workspace.rootTilingContainer)
        floatingWindows = workspace.floatingWindows.map(FrozenWindow.init)
        macosUnconventionalWindows =
            workspace.macOsNativeHiddenAppsWindowsContainer.children.map { FrozenWindow($0 as! Window) } +
            workspace.macOsNativeFullscreenWindowsContainer.children.map { FrozenWindow($0 as! Window) }
        mostRecentWindowId = workspace.mostRecentWindowRecursive?.windowId
    }

    init(
        name: String,
        monitor: FrozenMonitor,
        rootTilingNode: FrozenContainer,
        floatingWindows: [FrozenWindow],
        macosUnconventionalWindows: [FrozenWindow],
        mostRecentWindowId: UInt32?,
    ) {
        self.name = name
        self.monitor = monitor
        self.rootTilingNode = rootTilingNode
        self.floatingWindows = floatingWindows
        self.macosUnconventionalWindows = macosUnconventionalWindows
        self.mostRecentWindowId = mostRecentWindowId
    }
}

func collectAllWindowIdsRecursive(_ node: TreeNode) -> [UInt32] {
    if let window = node as? Window { return [window.windowId] }
    var result = [UInt32]()
    for child in node.children {
        result += collectAllWindowIdsRecursive(child)
    }
    return result
}

@MainActor func bindMacosUnconventionalWindow(_ window: Window, _ frozen: FrozenWindow, _ workspace: Workspace) {
    let container: NonLeafTreeNodeObject = frozen.macosParentKind == .macosHiddenAppsWindowsContainer
        ? workspace.macOsNativeHiddenAppsWindowsContainer
        : workspace.macOsNativeFullscreenWindowsContainer
    window.bind(to: container, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
    // normalizeLayoutReason moves the window back once it's no longer fullscreen/hidden
    window.layoutReason = .macos(prevParentKind: frozen.macosPrevParentKind ?? .tilingContainer)
}

@MainActor func restoreHiddenInCorner(_ window: Window, _ frozen: FrozenWindow) {
    if let position = frozen.unhiddenProportionalPosition, let window = window as? MacWindow, !window.isHiddenInCorner {
        window.restoreHiddenInCorner(unhiddenProportionalPosition: position)
    }
}

/// Windows that can't be found are skipped, and the indices of the following ones stay correct
@MainActor private func restoreTreeRecursive(
    _ frozenContainer: FrozenContainer,
    parent: NonLeafTreeNodeObject,
    index: Int,
    _ lookup: (FrozenWindow) -> Window?,
) {
    let container = TilingContainer(
        parent: parent,
        adaptiveWeight: frozenContainer.weight,
        frozenContainer.orientation,
        frozenContainer.layout,
        index: index,
    )
    var index = 0
    for child in frozenContainer.children {
        switch child {
            case .window(let frozen):
                guard let window = lookup(frozen) else { continue }
                window.layoutReason = .standard
                window.bind(to: container, adaptiveWeight: frozen.weight, index: index)
            case .container(let c):
                restoreTreeRecursive(c, parent: container, index: index, lookup)
        }
        index += 1
    }
}
