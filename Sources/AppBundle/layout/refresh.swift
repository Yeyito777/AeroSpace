import AppKit
import Common

@MainActor
private var activeRefreshTask: Task<(), any Error>? = nil

@MainActor
final class NativeFocusSyncRequest: Sendable {
    var isRequested = false
}

@TaskLocal
var nativeFocusSyncRequest: NativeFocusSyncRequest? = nil

@MainActor
func requestNativeFocusSync() {
    nativeFocusSyncRequest?.isRequested = true
}

@MainActor
func syncFocusToMacOs(_ target: LiveFocus) {
    if let window = target.windowOrNil {
        window.nativeFocus()
    } else {
        // AeroSpace workspaces are virtual. Owning native focus while an empty
        // workspace is active prevents macOS from surfacing an app whose
        // windows belong to a hidden workspace.
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
func scheduleCancellableCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) {
    let request = WindowDetectionScheduler.CompleteRefreshRequest(
        event: event,
        optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces,
    )
    if windowDetectionScheduler.deferCompleteRefreshIfDetecting(request) { return }
    activeRefreshTask?.cancel()
    activeRefreshTask = Task.startUnstructured { @MainActor in
        try checkCancellation()
        await runHeavyCompleteRefreshSession(
            event,
            assumeCancellable: true,
            optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces,
        )
    }
}

@MainActor
func cancelActiveCompleteRefresh() {
    activeRefreshTask?.cancel()
    activeRefreshTask = nil
}

@MainActor
func runHeavyCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    assumeCancellable: Bool,
    layoutWorkspaces shouldLayoutWorkspaces: Bool = true,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) async {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    if !TrayMenuModel.shared.isEnabled { return }
    let res = await Result {
        try await $refreshSessionEvent.withValue(event) {
            let nativeFocused = try await getNativeFocusedWindow(.cancellable)
            if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
            updateFocusCache(nativeFocused)

            if shouldLayoutWorkspaces && optimisticallyPreLayoutWorkspaces { try await layoutWorkspaces() }

            await refreshModel_nonCancellable()
            try await refresh()
            if event.isStartup { try await restoreStartupWorld() }
            gcMonitors()

            updateTrayText()
            SecureInputPanel.shared.refresh()
            try await normalizeLayoutReason()
            if shouldLayoutWorkspaces { try await layoutWorkspaces() }
        }
    }
    switch res {
        case .success(()): schedulePersistentWorldSave()
        case .failure(let err as CancellationError): check(assumeCancellable, "Non cancellable refresh session was canceled: \(err) (\(type(of: err)))")
        case .failure(let err): die("Illegal error: \(err)")
    }
}

@MainActor
func runLightSession<T>(
    _ event: RefreshSessionEvent,
    _: RunSessionGuard,
    body: @MainActor () async throws -> T,
) async throws -> T {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    activeRefreshTask?.cancel() // Give priority to runSession
    activeRefreshTask = nil
    let syncRequest = NativeFocusSyncRequest()
    return try await $nativeFocusSyncRequest.withValue(syncRequest) {
        try await $refreshSessionEvent.withValue(event) {
            let nativeFocused = try await getNativeFocusedWindow(.cancellable)
            if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
            updateFocusCache(nativeFocused)
            let focusBefore = focus

            await refreshModel_nonCancellable()
            let result = try await body()
            await refreshModel_nonCancellable()

            let focusAfter = focus

            updateTrayText()
            SecureInputPanel.shared.refresh()
            if !event.isFocusFollowsMouse { try await layoutWorkspaces() }
            if focusBefore != focusAfter || syncRequest.isRequested {
                syncFocusToMacOs(focusAfter)
            }
            if !event.isFocusFollowsMouse { scheduleCancellableCompleteRefreshSession(event) }
            schedulePersistentWorldSave()
            return result
        }
    }
}

struct RunSessionGuard: Sendable {
    @MainActor
    static var isServerEnabled: RunSessionGuard? { TrayMenuModel.shared.isEnabled ? forceRun : nil }
    @MainActor
    static func isServerEnabled(orIsEnableCommand command: (any Command)?) -> RunSessionGuard? {
        command is EnableCommand ? .forceRun : .isServerEnabled
    }
    @MainActor
    static func checkServerIsEnabledOrDie(
        file: StaticString = #fileID,
        line: Int = #line,
        column: Int = #column,
        function: String = #function,
    ) -> RunSessionGuard {
        .isServerEnabled ?? dieT("server is disabled", file: file, line: line, column: column, function: function)
    }
    static let forceRun = RunSessionGuard()
    private init() {}
}

@MainActor
func refreshModel_nonCancellable() async {
    if refreshSessionEvent?.isFocusFollowsMouse == true {
        await checkOnFocusChangedCallbacks_nonCancellable()
    } else {
        Workspace.garbageCollectUnusedWorkspaces()
        await checkOnFocusChangedCallbacks_nonCancellable()
        normalizeContainers()
    }
}

@MainActor
private func refresh() async throws {
    // Garbage collect terminated apps and windows before working with all windows
    let registrationsBeforeSnapshot = MacWindow.registrationCount
    let mapping = try await MacApp.refreshAllAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    let aliveWindowIds = mapping.values.flatMap(id).toSet()

    for window in MacWindow.allWindows {
        if isDeadAfterWindowsSnapshot(
            windowId: window.windowId,
            registrationIndex: window.registrationIndex,
            aliveWindowIds: aliveWindowIds,
            registrationsBeforeSnapshot: registrationsBeforeSnapshot,
        ) {
            window.garbageCollect(skipClosedWindowsCache: false)
        }
    }
    for (app, windowIds) in mapping {
        for windowId in windowIds {
            try await MacWindow.getOrRegister(windowId: windowId, macApp: app)
        }
    }

    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
}

/// A window registered while the snapshot was being taken (e.g. by a window detection session or by
/// getNativeFocusedWindow of a concurrent session) may be missing from the snapshot, but it's not dead
func isDeadAfterWindowsSnapshot(
    windowId: UInt32,
    registrationIndex: UInt64,
    aliveWindowIds: Set<UInt32>,
    registrationsBeforeSnapshot: UInt64,
) -> Bool {
    !aliveWindowIds.contains(windowId) && registrationIndex < registrationsBeforeSnapshot
}

func refreshObs(_: AXObserver, _: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    Task.startUnstructured { @MainActor in
        if !TrayMenuModel.shared.isEnabled { return }
        scheduleCancellableCompleteRefreshSession(.ax(notif))
    }
}

/// Bounds the layout retries for an app that stays unresponsive. Retries resume once they have been quiet for a while
struct AxCooldownLayoutRetryBudget {
    static let maxConsecutiveRetries = 5
    static let resetAfter: Duration = .seconds(5)

    private var retries = 0
    private var lastRetry: ContinuousClock.Instant? = nil

    mutating func takeRetry(now: ContinuousClock.Instant) -> Bool {
        if let lastRetry, now - lastRetry > Self.resetAfter { retries = 0 }
        if retries >= Self.maxConsecutiveRetries { return false }
        retries += 1
        lastRetry = now
        return true
    }
}

@MainActor private var axCooldownLayoutRetryBudget = AxCooldownLayoutRetryBudget()
@MainActor private var axCooldownLayoutRetryTask: Task<(), Never>? = nil

/// AX requests to an app in its circuit breaker cooldown are dropped (see AxAppCircuitBreakerState). A dropped frame
/// change leaves the window where it was, e.g. on screen on top of another workspace, and nothing else might lay the
/// windows out again soon. From any thread
func retryLayoutAfterAxCooldown(pid: pid_t) {
    Task.startUnstructured { @MainActor in
        if axCooldownLayoutRetryTask != nil { return } // The scheduled refresh lays out every window
        guard axCooldownLayoutRetryBudget.takeRetry(now: .now) else { return }
        let delay = (axCooldownRemaining(for: pid) ?? .zero) + .milliseconds(10)
        axCooldownLayoutRetryTask = Task.startUnstructured { @MainActor in
            try? await Task.sleep(for: delay)
            axCooldownLayoutRetryTask = nil
            scheduleCancellableCompleteRefreshSession(.axCooldownLayoutRetry)
        }
    }
}

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

@MainActor
func layoutWorkspaces() async throws {
    if !TrayMenuModel.shared.isEnabled {
        for workspace in Workspace.all {
            workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
            try await workspace.layoutWorkspace() // Unhide tiling windows from corner
        }
        return
    }
    let monitors = monitors
    var monitorToOptimalHideCorner: [CGPoint: OptimalHideCorner] = [:]
    for monitor in monitors {
        let xOff = monitor.width * 0.1
        let yOff = monitor.height * 0.1
        // brc = bottomRightCorner
        let brc1 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: -yOff)
        let brc2 = monitor.rect.bottomRightCorner + CGPoint(x: -xOff, y: 2)
        let brc3 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: 2)

        // blc = bottomLeftCorner
        let blc1 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff)
        let blc2 = monitor.rect.bottomLeftCorner + CGPoint(x: xOff, y: 2)
        let blc3 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: 2)

        func contains(_ monitor: Monitor, _ point: CGPoint) -> Int { monitor.rect.contains(point) ? 1 : 0 }
        let important = 10

        let corner: OptimalHideCorner =
            monitors.sumOfInt { contains($0, blc1) + contains($0, blc2) + important * contains($0, blc3) } <
            monitors.sumOfInt { contains($0, brc1) + contains($0, brc2) + important * contains($0, brc3) }
            ? .bottomLeftCorner
            : .bottomRightCorner
        monitorToOptimalHideCorner[monitor.rect.topLeftCorner] = corner
    }

    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    for monitor in monitors {
        let workspace = monitor.activeWorkspace
        workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
        try await workspace.layoutWorkspace()
    }
    for workspace in Workspace.all where !workspace.isVisible {
        let corner = monitorToOptimalHideCorner[workspace.workspaceMonitor.rect.topLeftCorner] ?? .bottomRightCorner
        for window in workspace.allLeafWindowsRecursive {
            try await (window as! MacWindow).hideInCorner(corner) // todo as!
        }
    }
}

@MainActor
private func normalizeContainers() {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.all {
        workspace.normalizeContainers()
    }
}
