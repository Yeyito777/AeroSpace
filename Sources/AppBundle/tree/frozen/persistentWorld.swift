import AppKit
import Common

/// The FrozenWorld persisted on disk, so that an AeroSpace restart (`aerospace restart`, upgrade, crash, quit and
/// launch) puts every window back where it was.
///
/// Window ids are only meaningful while the process that owns the window lives. Every window remembers its app
/// (pid, bundle id, launch time) and windows of apps that are no longer the same process are dropped on load.
///
/// The world is saved with a debounce after sessions, on termination and by `aerospace restart`.
/// On startup, windows of the saved world are registered right into their saved workspace (instead of the
/// "active workspace of the monitor" startup placement), and once the startup refresh registered all windows,
/// the saved trees, monitors and focus are restored. Windows that show up only later (e.g. windows of other macOS
/// Spaces) are still put into their saved workspace when detected.
enum PersistentWorld {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(aeroSpaceAppId)/world.json")
    }

    static func encode(_ world: FrozenWorld) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return Result { try encoder.encode(world) }.getOrDie()
    }

    static func decode(_ data: Data) -> FrozenWorld? {
        guard let world = try? JSONDecoder().decode(FrozenWorld.self, from: data) else { return nil }
        return world.formatVersion == FrozenWorld.currentFormatVersion ? world : nil
    }

    /// Windows of apps that are no longer the same process are dropped
    static func load() -> FrozenWorld? {
        (try? Data(contentsOf: url)).flatMap(decode)?.filterWindows { $0.app.map(isSameLiveApp) == true }
    }

    fileprivate static func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

func isSameLiveApp(_ app: FrozenApp) -> Bool {
    guard let running = NSRunningApplication(processIdentifier: app.pid),
          !running.isTerminated,
          running.bundleIdentifier == app.bundleId
    else { return false }
    if let launchTime = app.launchTime, let launchDate = running.launchDate {
        return abs(launchDate.timeIntervalSince1970 - launchTime) < 2
    }
    return true
}

extension FrozenApp {
    func matches(_ app: any AbstractApp) -> Bool { pid == app.pid && bundleId == app.rawAppBundleId }
}

// MARK: - Saving

/// Saving starts only after the startup restore, otherwise the startup "everything on one workspace" state would
/// overwrite the world that is being restored
@MainActor var isPersistentWorldSavingEnabled = false
@MainActor private var lastSavedWorld: Data? = nil
@MainActor private var saveTask: Task<(), Never>? = nil

@MainActor func schedulePersistentWorldSave() {
    if !isPersistentWorldSavingEnabled || saveTask != nil { return }
    saveTask = Task.startUnstructured { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        saveTask = nil
        savePersistentWorldNow()
    }
}

/// Returns an error message if the world couldn't be saved
@MainActor @discardableResult
func savePersistentWorldNow() -> String? {
    if !isPersistentWorldSavingEnabled || isUnitTest || serverArgs.isReadOnly { return nil }
    // Lock screen makes all windows unobservable. Don't save the world without them. See closedWindowsCache
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lockScreenAppBundleId { return nil }
    let world = FrozenWorld.capture()
    // Closing the last window leaves a stale but harmless file: dead windows are dropped on load
    if world.allWindows.isEmpty { return nil }
    let data = PersistentWorld.encode(world)
    if data == lastSavedWorld { return nil }
    do {
        try PersistentWorld.write(data)
        lastSavedWorld = data
        return nil
    } catch {
        return "Can't save \(PersistentWorld.url.path): \(error.localizedDescription)"
    }
}

// MARK: - Restoring

struct WindowPlacement: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case tiling, floating, macosUnconventional }
    let workspace: String
    let kind: Kind
    let window: FrozenWindow
}

extension FrozenWorld {
    /// Where windows go when they are registered
    var placements: [UInt32: WindowPlacement] {
        var result: [UInt32: WindowPlacement] = [:]
        for workspace in workspaces {
            for window in workspace.rootTilingNode.allWindowsRecursive {
                result[window.id] = WindowPlacement(workspace: workspace.name, kind: .tiling, window: window)
            }
            for window in workspace.floatingWindows {
                result[window.id] = WindowPlacement(workspace: workspace.name, kind: .floating, window: window)
            }
            for window in workspace.macosUnconventionalWindows {
                result[window.id] = WindowPlacement(workspace: workspace.name, kind: .macosUnconventional, window: window)
            }
        }
        return result
    }
}

@MainActor private var pendingWindowPlacements: [UInt32: WindowPlacement] = [:]
@MainActor private var startupWorld: FrozenWorld? = nil

/// Must be called before the startup refresh
@MainActor func prepareStartupRestore(_ world: FrozenWorld) {
    startupWorld = world
    pendingWindowPlacements = world.placements
    // Windows that the world doesn't know go to the active workspace of their monitor
    world.restoreMonitors()
    if let focusedWorkspace = world.focusedWorkspace {
        _ = Workspace.get(byName: focusedWorkspace).focusWorkspace()
    }
}

/// The saved placement of the window if the window belongs to the same app process as when it was saved
@MainActor func pendingWindowPlacement(windowId: UInt32, app: any AbstractApp) -> WindowPlacement? {
    guard let placement = pendingWindowPlacements[windowId] else { return nil }
    return placement.window.app?.matches(app) == true ? placement : nil
}

/// Called right after a window of the saved world is registered (it's already bound to placement.workspace)
@MainActor func applyWindowPlacement(_ window: Window, _ placement: WindowPlacement) async throws {
    pendingWindowPlacements.removeValue(forKey: window.windowId)
    if window.parent is MacosPopupWindowsContainer { return } // Not a window anymore
    let workspace = Workspace.get(byName: placement.workspace)
    switch placement.kind {
        case .tiling:
            if window.isFloating { try await window.relayoutWindow(on: workspace, .cancellable, forceTile: true) }
        case .floating:
            window.bindAsFloatingWindow(to: workspace)
        case .macosUnconventional:
            bindMacosUnconventionalWindow(window, placement.window, workspace)
    }
    restoreHiddenInCorner(window, placement.window)
}

/// Called by the startup refresh once it registered all windows
@MainActor func restoreStartupWorld() async throws {
    guard let world = startupWorld else { return }
    startupWorld = nil
    try await world.restore(restoreFocus: true) { frozen in
        MacWindow.allWindowsMap[frozen.id]?.takeIf { frozen.app?.matches($0.app) == true }
    }
}
