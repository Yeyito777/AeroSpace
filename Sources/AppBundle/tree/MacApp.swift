import AppKit
import Common

func canFocusByActivatingAppOnly(
    lastNativeFocusedWindowId: UInt32?,
    targetWindowId: UInt32,
) -> Bool {
    lastNativeFocusedWindowId == targetWindowId
}

// Potential alternative implementation
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
// (only available since macOS 14)
final class MacApp: AbstractApp {
    /*conforms*/ let pid: Int32
    /*conforms*/ let rawAppBundleId: String?
    let appId: KnownBundleId?
    let nsApp: NSRunningApplication
    private let axApp: ThreadGuardedValue<AXUIElement>
    private let appAxSubscriptions: ThreadGuardedValue<[AxSubscription]> // keep subscriptions in memory
    private let windows: ThreadGuardedValue<[UInt32: AxWindow]> = .init([:])
    var lastNativeFocusedWindowId: UInt32? = nil
    private var thread: Thread?
    private var setFrameJobs: [UInt32: RunLoopJob] = [:]
    @MainActor private var didCompleteInitialWindowRefresh = false
    @MainActor private static var focusJob: RunLoopJob? = nil

    /*conforms*/ var name: String? { nsApp.localizedName }
    /*conforms*/ var execPath: String? { nsApp.executableURL?.path }
    /*conforms*/ var bundlePath: String? { nsApp.bundleURL?.path }

    // todo think if it's possible to integrate this global mutable state to https://github.com/nikitabobko/AeroSpace/issues/1215
    //      and make deinitialization automatic in deinit
    @MainActor static var allAppsMap: [pid_t: MacApp] = [:]
    @MainActor private static var wipPids: [pid_t: AwaitableOneTimeBroadcastLatch] = [:]

    private init(
        _ nsApp: NSRunningApplication,
        _ axApp: AXUIElement,
        _ axSubscriptions: [AxSubscription],
        _ thread: Thread,
    ) {
        self.nsApp = nsApp
        self.axApp = .init(axApp)
        self.pid = nsApp.processIdentifier
        self.rawAppBundleId = nsApp.bundleIdentifier
        self.appId = nsApp.bundleIdentifier.flatMap { KnownBundleId.init(rawValue: $0) }
        assert(!axSubscriptions.isEmpty)
        self.appAxSubscriptions = .init(axSubscriptions)
        self.thread = thread
    }

    @MainActor
    @discardableResult
    static func getOrRegister(_ nsApp: NSRunningApplication) async throws -> MacApp? {
        // Don't perceive any of the lock screen windows as real windows
        // Otherwise, false positive ax notifications might trigger that lead to gcWindows
        if nsApp.bundleIdentifier == lockScreenAppBundleId { return nil }
        let pid = nsApp.processIdentifier
        // AX requests crash if you send them to yourself
        if pid == myPid { return nil }

        if let existing = allAppsMap[pid] { return existing }
        try checkCancellation()
        if let wip = wipPids[pid] {
            try await wip.await()
            return allAppsMap[pid]
        }
        let wip = AwaitableOneTimeBroadcastLatch()
        wipPids[pid] = wip

        let thread = Thread {
            $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: nsApp.idForDebug)) {
                let axApp = AXUIElementCreateApplication(nsApp.processIdentifier)
                let handlers: HandlerToNotifKeyMapping = unsafe [
                    (windowCreatedObs, [kAXWindowCreatedNotification]),
                    (refreshObs, [kAXFocusedWindowChangedNotification]),
                ]
                let job = RunLoopJob(.cancellable)
                let subscriptions = (try? unsafe AxSubscription.bulkSubscribe(
                    nsApp,
                    axApp,
                    job,
                    handlers,
                    phase: .appRegistration,
                )) ?? []
                let isGood = !subscriptions.isEmpty
                let app = isGood ? MacApp(nsApp, axApp, subscriptions, Thread.current) : nil

                let appAxSubscriptionsThreadGuarded = app?.appAxSubscriptions
                let windowsThreadGuarded = app?.windows
                let axAppThreadGuarded = app?.axApp

                Task.startUnstructured { @MainActor in
                    allAppsMap[pid] = app
                    wipPids[pid] = nil
                    await wip.signalToAll()
                }
                if isGood {
                    CFRunLoopRun()

                    // Destroy AX objects in reverse order of their creation
                    appAxSubscriptionsThreadGuarded?.destroy()
                    windowsThreadGuarded?.destroy()
                    axAppThreadGuarded?.destroy()
                }
            }
        }
        thread.name = "AxAppThread \(nsApp.idForDebug)"
        thread.start()

        try await wip.await()
        return allAppsMap[pid]
    }

    func closeAndUnregisterAxWindow(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        _ = withWindowAsync(windowId, .cancellable) { [windows] window, job in
            guard let closeButton = window.get(Ax.closeButtonAttr) else { return }
            if closeButton.cast.perform(kAXPressAction) {
                windows.threadGuarded.removeValue(forKey: windowId)
            }
        }
    }

    func getAxSize(_ windowId: UInt32, _ cm: CancellationMode) async throws -> CGSize? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.sizeAttr)
        }
    }

    // todo merge together with detectNewWindows
    func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
        if shouldSkipAxRequests(for: pid) { return nil }
        let windowId: UInt32? = try await thread?.runInLoop(cm) { [pid, nsApp, axApp, windows] job -> UInt32? in
            if shouldSkipAxRequests(for: pid) { return nil }
            return try axApp.threadGuarded.get(Ax.focusedWindowAttr)
                .flatMap { try windows.threadGuarded.getOrRegisterAxWindow(windowId: $0.windowId, $0.ax.cast, nsApp, job) }?
                .windowId
        }
        guard let windowId else { return nil }
        return try await MacWindow.getOrRegister(windowId: windowId, macApp: self)
    }

    @MainActor func nativeFocus(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        MacApp.focusJob?.cancel()
        // Performance optimization. If possible avoid doing AX requests
        // (important for apps which are slow at responding even such basic AX requests. E.g. Godot)
        // Activation alone is safe only after AX has confirmed the target as
        // this app's native focused window. A fresh single-window app can
        // publish a non-key window, so it still needs the main/raise actions.
        // Beware of the macOS bug: https://github.com/nikitabobko/AeroSpace/issues/101
        if (!NSScreen.screensHaveSeparateSpaces || monitors.count == 1) &&
            canFocusByActivatingAppOnly(
                lastNativeFocusedWindowId: lastNativeFocusedWindowId,
                targetWindowId: windowId,
            )
        {
            nsApp.activate(options: .activateIgnoringOtherApps)
        } else {
            MacApp.focusJob = withWindowAsync(windowId, .cancellable) { [nsApp] window, job in
                // Raise firstly to make sure that by the time we activate the app, the window would be already on top
                window.set(Ax.isMainAttr, true)
                window.perform(kAXRaiseAction)
                nsApp.activate(options: .activateIgnoringOtherApps)
            }
        }
    }

    func setAxFrame(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        let retryLayout: @Sendable () -> () = { [pid] in retryLayoutAfterAxCooldown(pid: pid) }
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable, onAxCooldown: retryLayout) { [axApp, pid] window, job in
            try disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job)
            }
            // The app stopped answering while the frame was being changed
            if shouldSkipAxRequests(for: pid) { retryLayout() }
        }
    }

    func setAxFrameForTermination(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        if shouldSkipAxRequests(for: pid) { return }
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        let semaphore = DispatchSemaphore(value: 0)
        let job = withWindowAsync(windowId, .nonCancellable) { [axApp] window, job in
            try? disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job)
            }
            semaphore.signal()
        }
        switch job.isCancelled {
            case true: return
            case false: semaphore.wait()
        }
    }

    func getAxWindowsCount(_ cm: CancellationMode) async throws -> Int? {
        if shouldSkipAxRequests(for: pid) { return nil }
        return try await thread?.runInLoop(cm) { [pid, axApp] job in
            if shouldSkipAxRequests(for: pid) { return nil }
            return axApp.threadGuarded.get(Ax.windowsAttr)?.count
        }
    }

    func getAxRect(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Rect? {
        try await withWindow(windowId, cm) { window, job in
            try AppBundle.getAxRect(window: window, job: job)
        }
    }

    func getAxRectForTermination(_ windowId: UInt32) -> Rect? {
        if shouldSkipAxRequests(for: pid) { return nil }
        let future = CompletableFuture<Rect?>()
        let job = withWindowAsync(windowId, .nonCancellable) { window, job in
            future.complete(try AppBundle.getAxRect(window: window, job: job))
        }
        return switch job.isCancelled {
            case true: nil
            case false: future.blockingGet()
        }
    }

    func isWindowHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.isWindowHeuristic(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } == true
    }

    func getAxUiElementWindowType(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.getWindowType(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } ?? .window
    }

    func isDialogHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        try await withWindow(windowId, cm) { [appId] window, job in
            window.isDialogHeuristic(appId, windowLevel)
        } == true
    }

    func setNativeFullscreen(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.isFullscreenAttr, value)
        }
    }

    func setNativeMinimized(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.minimizedAttr, value)
        }
    }

    func dumpWindowAxInfo(windowId: UInt32, _ cm: CancellationMode) async throws -> [String: Json] {
        try await withWindow(windowId, cm) { window, job in
            dumpAxRecursive(window, .window)
        } ?? [:]
    }

    func dumpAppAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        if shouldSkipAxRequests(for: pid) { return [:] }
        return try await thread?.runInLoop(cm) { [pid, axApp] job in
            if shouldSkipAxRequests(for: pid) { return [:] }
            return dumpAxRecursive(axApp.threadGuarded, .app)
        } ?? [:]
    }

    func getAxTitle(_ windowId: UInt32, _ cm: CancellationMode) async throws -> String? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.titleAttr)
        }
    }

    func isMacosNativeFullscreen(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.isFullscreenAttr)
        }
    }

    func isMacosNativeMinimized(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.minimizedAttr)
        }
    }

    @MainActor
    static func refreshAllAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [MacApp: [UInt32]] {
        for (_, app) in MacApp.allAppsMap { // gc dead apps
            try checkCancellation()
            if app.nsApp.isTerminated {
                await app.destroy()
            }
        }
        return try await withThrowingTaskGroup(of: (pid_t, [UInt32]).self, returning: [MacApp: [UInt32]].self) { group in
            func refreshTheApp(_ nsApp: NSRunningApplication) {
                group.addTask { @Sendable @MainActor in
                    guard let app = try await MacApp.getOrRegister(nsApp) else { return (nsApp.processIdentifier, []) }
                    return (nsApp.processIdentifier, try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: frontmostAppBundleId).alive)
                }
            }
            // Register new apps
            for nsApp in NSWorkspace.shared.runningApplications {
                try checkCancellation()
                if isWatchedApp(nsApp) {
                    refreshTheApp(nsApp)
                }
            }
            for (_, app) in MacApp.allAppsMap {
                try checkCancellation()
                // "About this Mac" window, TouchID, and a lot of other utility windows
                // We don't monitor them actively as we do for regular apps, but if a window of one of those utility
                // apps got focused it will end up in allAppsMap
                if !isWatchedApp(app.nsApp) {
                    refreshTheApp(app.nsApp)
                }
            }
            var result: [MacApp: [UInt32]] = [:]
            for try await (pid, windowIds) in group {
                if let app = MacApp.allAppsMap[pid] {
                    result[app] = windowIds
                }
            }
            return result
        }
    }

    /// Fetches the windows of this app (and describes the new ones) for registerWindows. Dead windows are left to the
    /// complete refresh. `createdWindow` is the element of kAXWindowCreatedNotification. It's registered even if the
    /// app doesn't list it in kAXWindowsAttribute (yet)
    @MainActor func fetchWindows(createdWindow: AxElementBox?) async throws -> (alive: [UInt32], report: AxWindowsRefreshReport) {
        try await refreshAndGetAliveWindowIds(
            frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            createdWindow: createdWindow,
            describeNewWindows: true,
        )
    }

    /// Registers the result of fetchWindows
    @MainActor func registerWindows(_ fetched: (alive: [UInt32], report: AxWindowsRefreshReport)) async throws {
        for windowId in fetched.alive {
            try await MacWindow.getOrRegister(windowId: windowId, macApp: self, prefetched: fetched.report.newWindows[windowId])
        }
    }

    @MainActor private func refreshAndGetAliveWindowIds(
        frontmostAppBundleId: String?,
        createdWindow: AxElementBox? = nil,
        describeNewWindows: Bool = false,
    ) async throws -> (alive: [UInt32], report: AxWindowsRefreshReport) {
        if nsApp.isTerminated {
            await destroy()
            return ([], AxWindowsRefreshReport(skipped: "app terminated"))
        }
        if shouldSkipAxRequests(for: pid) {
            return (MacWindow.allWindows.filter { $0.app.pid == pid }.map(\.windowId), AxWindowsRefreshReport(skipped: "circuit breaker"))
        }
        guard let thread else { return ([], AxWindowsRefreshReport(skipped: "no app thread")) }
        let phase: AxRequestPhase = didCompleteInitialWindowRefresh ? .establishedApp : .appRegistration
        let (alive, dead, completedWindowRefresh, report) = try await thread.runInLoop(.cancellable) {
            [pid, nsApp, windows, axApp, appId] (job) -> ([UInt32], [UInt32], Bool, AxWindowsRefreshReport) in
            let cached: [UInt32: AxWindow] = windows.threadGuarded
            var report = AxWindowsRefreshReport()
            if shouldSkipAxRequests(for: pid) {
                report.skipped = "circuit breaker"
                return (Array(cached.keys), [], false, report)
            }
            var alive = cached
            var dead = [UInt32: AxWindow]()
            // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
            // Second and third lines of defence are technically needed only to avoid potential flickering
            if frontmostAppBundleId != lockScreenAppBundleId {
                for (windowId, window) in cached {
                    try job.checkCancellation()
                    let result = window.ax.containingWindowIdWithError()
                    if result.error == .cannotComplete {
                        report.skipped = "known window \(windowId): cannotComplete"
                        return (Array(cached.keys), [], false, report)
                    }
                    if result.windowId == nil {
                        alive[windowId] = nil
                        dead[windowId] = window
                    }
                }
            }

            let clock = ContinuousClock()
            let start = clock.now
            let reportedWindows = axApp.threadGuarded.getWithError(Ax.windowsAttr, phase: phase)
            report.windowsQuery = clock.now - start
            report.reported = reportedWindows.value?.map(\.windowId) ?? []
            if reportedWindows.error != .success { report.windowsError = reportedWindows.error.rawValue }
            if reportedWindows.error == .cannotComplete {
                report.skipped = "kAXWindowsAttribute: cannotComplete"
                return (Array(cached.keys), [], false, report)
            }
            func register(_ id: UInt32, _ window: AXUIElement) throws {
                if alive[id] != nil { return }
                let start = clock.now
                try alive.getOrRegisterAxWindow(windowId: id, window, nsApp, job)
                report.subscriptions += clock.now - start
                if alive[id] == nil {
                    report.rejected.append("\(id): \(isLeftMouseButtonDown ? "mouse down" : "AX subscription failed")")
                }
            }
            for (id, window) in reportedWindows.value ?? [] {
                try job.checkCancellation()
                try register(id, window)
            }
            if let createdWindow, alive.count == cached.count - dead.count {
                // The app reported no new window, but it notified about one
                let result = createdWindow.ax.containingWindowIdWithError()
                report.createdWindowId = result.windowId
                if result.error != .success { report.createdWindowError = result.error.rawValue }
                if let id = result.windowId, alive[id] == nil {
                    try register(id, createdWindow.ax)
                    if alive[id] != nil { report.registeredFromNotification = true }
                }
            }

            if describeNewWindows {
                // Everything that registering and laying out the new windows needs, while the app is answering.
                // Saves round trips through the main thread, each of which can find the app busy again
                let start = clock.now
                for (id, window) in alive where cached[id] == nil {
                    try job.checkCancellation()
                    let type = window.ax.getWindowType(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, getWindowLevelOffMainThread(for: id))
                    let rect = try AppBundle.getAxRect(window: window.ax, job: job)
                    let isFullscreen = window.ax.get(Ax.isFullscreenAttr) == true
                    let isMinimized = !isFullscreen && window.ax.get(Ax.minimizedAttr) == true
                    report.newWindows[id] = NewWindowDescription(type: type, rect: rect, isMacosFullscreen: isFullscreen, isMacosMinimized: isMinimized)
                }
                report.describe = clock.now - start
            }

            windows.threadGuarded = alive
            return (Array(alive.keys), Array(dead.keys), true, report)
        }
        if completedWindowRefresh { didCompleteInitialWindowRefresh = true }
        for windowId in dead {
            setFrameJobs.removeValue(forKey: windowId)?.cancel()
        }
        return (alive, report)
    }

    private func destroy() async {
        _ = await Task.startUnstructured { @MainActor [pid] in _ = MacApp.allAppsMap.removeValue(forKey: pid) }.result
        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]
        thread?.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { job in CFRunLoopStop(CFRunLoopGetCurrent()) }
        thread = nil // Disallow all future job submissions
    }

    private func withWindow<T>(
        _ windowId: UInt32,
        _ cm: CancellationMode,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> T?,
    ) async throws -> T? {
        if shouldSkipAxRequests(for: pid) { return nil }
        return try await thread?.runInLoop(cm) { [pid, windows] job in
            if shouldSkipAxRequests(for: pid) { return nil }
            guard let window = windows.threadGuarded[windowId] else { return nil }
            return try body(window.ax, job)
        }
    }

    /// `onAxCooldown` is called if the job is dropped because the app is in its circuit breaker cooldown
    private func withWindowAsync(
        _ windowId: UInt32,
        _ cm: CancellationMode,
        onAxCooldown: (@Sendable () -> ())? = nil,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> (),
    ) -> RunLoopJob {
        if shouldSkipAxRequests(for: pid) {
            onAxCooldown?()
            return .cancelled
        }
        return thread?.runInLoopAsync(job: RunLoopJob(cm)) { [pid, windows] job in
            if shouldSkipAxRequests(for: pid) {
                onAxCooldown?()
                return
            }
            guard let window = windows.threadGuarded[windowId] else { return }
            try? body(window.ax, job)
        } ?? .cancelled
    }
}

/// Apps whose windows are looked for in every complete refresh, not only once one of them is focused
private func isWatchedApp(_ nsApp: NSRunningApplication) -> Bool {
    // Steam's windows belong to its accessory helper process. A Steam window that shows up without being focused would
    // stay on screen on top of every workspace
    nsApp.activationPolicy == .regular || nsApp.bundleIdentifier == KnownBundleId.steam.rawValue
}

/// An AX element passed from an app thread to the main actor and back. AX elements are thread safe CF objects
final class AxElementBox: @unchecked Sendable {
    let ax: AXUIElement
    init(_ ax: AXUIElement) { self.ax = ax }
}

/// AX state of a new window, fetched together with the window list. See MacWindow.getOrRegister
struct NewWindowDescription: Sendable {
    let type: AxUiElementWindowType
    let rect: Rect?
    let isMacosFullscreen: Bool
    let isMacosMinimized: Bool
}

/// What the AX side of a window refresh saw. For the window detection timing log
struct AxWindowsRefreshReport: Sendable, CustomStringConvertible {
    var skipped: String? = nil
    var reported: [UInt32] = []
    var windowsError: Int32? = nil
    var rejected: [String] = []
    var createdWindowId: UInt32? = nil
    var createdWindowError: Int32? = nil
    var registeredFromNotification = false
    var windowsQuery: Duration = .zero
    var subscriptions: Duration = .zero
    var describe: Duration = .zero
    var newWindows: [UInt32: NewWindowDescription] = [:]

    /// The window of the notification is gone, there is nothing to wait for
    var isCreatedWindowGone: Bool { createdWindowError == AXError.invalidUIElement.rawValue }

    var description: String {
        var parts = ["query \(windowsQuery.ms)ms", "subscribe \(subscriptions.ms)ms", "describe \(describe.ms)ms", "reported \(reported)"]
        if let skipped { parts.append("skipped: \(skipped)") }
        if let windowsError { parts.append("AXWindows error \(windowsError)") }
        if !rejected.isEmpty { parts.append("rejected \(rejected)") }
        if let createdWindowId { parts.append("notification window \(createdWindowId)") }
        if let createdWindowError { parts.append("notification window error \(createdWindowError)") }
        if registeredFromNotification { parts.append("registered from the notification") }
        return "(" + parts.joined(separator: ", ") + ")"
    }
}

extension Duration {
    var ms: Double {
        let c = components
        return ((Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15) * 100).rounded() / 100
    }
}

private final class AxWindow {
    let windowId: UInt32
    let ax: AXUIElement
    // periphery:ignore
    private let axSubscriptions: [AxSubscription] // keep subscriptions in memory

    private init(windowId: UInt32, _ ax: AXUIElement, _ axSubscriptions: [AxSubscription]) {
        self.windowId = windowId
        self.ax = ax
        assert(!axSubscriptions.isEmpty)
        self.axSubscriptions = axSubscriptions
    }

    static func new(windowId: UInt32, _ ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        let handlers: HandlerToNotifKeyMapping = unsafe [
            (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
        ]
        let subscriptions = try unsafe AxSubscription.bulkSubscribe(nsApp, ax, job, handlers)
        return !subscriptions.isEmpty ? AxWindow(windowId: windowId, ax, subscriptions) : nil
    }
}

extension [UInt32: AxWindow] {
    @discardableResult
    fileprivate mutating func getOrRegisterAxWindow(windowId id: UInt32, _ axWindow: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        if let existing = self[id] { return existing }
        // Delay new window detection if mouse is down
        // It helps with apps that allow dragging their tabs out to create new windows
        // https://github.com/nikitabobko/AeroSpace/issues/1001
        if isLeftMouseButtonDown { return nil }

        if let window = try AxWindow.new(windowId: id, axWindow, nsApp, job) {
            self[id] = window
            return window
        } else {
            return nil
        }
    }
}

private func getAxRect(window: AXUIElement, job: RunLoopJob) throws -> Rect? {
    guard let topLeftCorner = window.get(Ax.topLeftCornerAttr) else { return nil }
    try job.checkCancellation()
    guard let size = window.get(Ax.sizeAttr) else { return nil }
    return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
}

private func setFrame(_ window: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?, _ job: RunLoopJob) throws {
    // Set size and then the position. The order is important https://github.com/nikitabobko/AeroSpace/issues/143
    //                                                        https://github.com/nikitabobko/AeroSpace/issues/335
    if let size { window.set(Ax.sizeAttr, size) }
    try job.checkCancellation()
    if let topLeft { window.set(Ax.topLeftCornerAttr, topLeft) } else { return }
    try job.checkCancellation()
    if let size { window.set(Ax.sizeAttr, size) }
}

// Some undocumented magic
// References: https://github.com/koekeishiya/yabai/commit/3fe4c77b001e1a4f613c26f01ea68c0f09327f3a
//             https://github.com/rxhanson/Rectangle/pull/285
private func disableAnimations<T>(app: AXUIElement, _ job: RunLoopJob, _ body: () throws -> T) throws -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    defer {
        if wasEnabled {
            app.set(Ax.enhancedUserInterfaceAttr, true)
        }
    }
    try job.checkCancellation()
    return try body()
}
