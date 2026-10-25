import AppKit
import Common

/// Fast path for kAXWindowCreatedNotification.
///
/// A complete refresh queries every running app and only reports the new window once the slowest app has answered.
/// The notification already says which app created a window, so a window detection session refreshes the windows of
/// that app only, registers the new ones (classification, on-window-detected callbacks, closed windows cache are
/// handled by MacWindow.getOrRegister as usual) and lays out the workspaces. A complete refresh is still scheduled
/// afterward to reconcile everything else.
///
/// While detection sessions run, complete refreshes are deferred instead of started: their AX requests would queue up
/// on the app threads ahead of the detection's ones.
struct WindowDetectionScheduler {
    struct CompleteRefreshRequest: Sendable {
        let event: RefreshSessionEvent
        let optimisticallyPreLayoutWorkspaces: Bool
    }

    /// pid -> whether another window was created while the session for the app was running
    private var sessions: [pid_t: Bool] = [:]
    private var deferredCompleteRefresh: CompleteRefreshRequest? = nil

    var isDetecting: Bool { !sessions.isEmpty }

    /// Returns true if the caller must start a session for the app.
    /// Returns false if a session for the app is already running. It will do one more pass.
    mutating func requestDetection(pid: pid_t) -> Bool {
        if sessions[pid] != nil {
            sessions[pid] = true
            return false
        }
        sessions[pid] = false
        return true
    }

    /// Returns true if the session must do one more pass because the app created another window meanwhile
    mutating func finishPass(pid: pid_t) -> Bool {
        if sessions[pid] == true {
            sessions[pid] = false
            return true
        }
        sessions[pid] = nil
        return false
    }

    mutating func endSession(pid: pid_t) {
        sessions[pid] = nil
    }

    /// Returns true if the complete refresh is deferred until the last detection session ends.
    /// Only the latest request is kept, in the same way as a newly scheduled complete refresh cancels the previous one.
    mutating func deferCompleteRefreshIfDetecting(_ request: CompleteRefreshRequest) -> Bool {
        if !isDetecting { return false }
        deferredCompleteRefresh = request
        return true
    }

    mutating func takeDeferredCompleteRefresh() -> CompleteRefreshRequest? {
        check(!isDetecting)
        defer { deferredCompleteRefresh = nil }
        return deferredCompleteRefresh
    }
}

@MainActor var windowDetectionScheduler = WindowDetectionScheduler()
/// Window detection sessions are only used after the startup refresh, because startup assigns windows differently.
/// See isStartup in MacWindow.getOrRegister
@MainActor var isWindowDetectionFastPathEnabled = false

func windowCreatedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notifiedAt = ContinuousClock.now
    let notif = notif as String
    var pid: pid_t = 0
    let pidOrNil: pid_t? = unsafe AXUIElementGetPid(ax, &pid) == .success ? pid : nil
    Task.startUnstructured { @MainActor in
        if !TrayMenuModel.shared.isEnabled { return }
        if let pidOrNil, isWindowDetectionFastPathEnabled {
            await runWindowDetectionSession(.ax(notif), pid: pidOrNil, notifiedAt: notifiedAt)
        } else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
        }
    }
}

@MainActor
func runWindowDetectionSession(_ event: RefreshSessionEvent, pid: pid_t, notifiedAt: ContinuousClock.Instant) async {
    if !windowDetectionScheduler.requestDetection(pid: pid) { return } // The running session will do one more pass
    let state = signposter.beginInterval(#function, "event: \(event) pid: \(pid)")
    defer { signposter.endInterval(#function, state) }
    cancelActiveCompleteRefresh() // Its AX requests would compete with the detection
    let timing = WindowDetectionTiming(notifiedAt: notifiedAt)
    var res: Result<(), any Error>
    repeat {
        res = await Result {
            try await $refreshSessionEvent.withValue(event) {
                try await windowDetectionPass(pid: pid, timing)
            }
        }
        if case .failure = res {
            windowDetectionScheduler.endSession(pid: pid)
            break
        }
    } while windowDetectionScheduler.finishPass(pid: pid)
    timing?.flush()
    schedulePersistentWorldSave()

    // Reconcile the rest of the world like any other ax notification would
    if !windowDetectionScheduler.isDetecting {
        let deferred = windowDetectionScheduler.takeDeferredCompleteRefresh()
        scheduleCancellableCompleteRefreshSession(
            deferred?.event ?? event,
            optimisticallyPreLayoutWorkspaces: deferred?.optimisticallyPreLayoutWorkspaces ?? false,
        )
    } else {
        scheduleCancellableCompleteRefreshSession(event) // deferred until the last detection session ends
    }
    switch res {
        case .success(()): break
        case .failure(let err as CancellationError): _ = err // Nobody cancels the session, but AX jobs are cancellable
        case .failure(let err): die("Illegal error: \(err)")
    }
}

/// The same steps as runHeavyCompleteRefreshSession, except that only the windows of one app are refreshed
@MainActor
private func windowDetectionPass(pid: pid_t, _ timing: WindowDetectionTiming?) async throws {
    if !TrayMenuModel.shared.isEnabled { return }
    // Lock screen makes all windows unobservable. Leave it to the complete refresh. See closedWindowsCache
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lockScreenAppBundleId { return }
    guard let app = MacApp.allAppsMap[pid] else { return }
    timing?.mark("main actor")
    let registrationsBefore = MacWindow.registrationCount

    let nativeFocused = try await getNativeFocusedWindow(.cancellable)
    if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
    updateFocusCache(nativeFocused)
    await refreshModel_nonCancellable()
    timing?.mark("native focus")

    try await app.registerNewWindows()
    Workspace.garbageCollectUnusedWorkspaces()
    // Including the window that getNativeFocusedWindow might have registered
    let newWindows = MacWindow.allWindows.filter { $0.registrationIndex >= registrationsBefore }
    timing?.mark("registered \(app.rawAppBundleId ?? "nil-bundle-id") \(newWindows.map(\.windowId))")
    // Popups (e.g. tooltips) aren't laid out. Don't double the layout work of the complete refresh for them
    if newWindows.allSatisfy({ $0.parent is MacosPopupWindowsContainer }) { return }

    updateTrayText()
    try await normalizeLayoutReason(newlyDetectedWindows: newWindows)
    try await layoutWorkspaces()
    timing?.mark("laid out")
}

/// Opt-in timing log for window detection. Enable: `mkdir -p ~/Library/Logs/AeroSpace && touch ~/Library/Logs/AeroSpace/window-detection.log`
/// Disable: delete the file
@MainActor
final class WindowDetectionTiming {
    private static let path = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/AeroSpace/window-detection.log").path
    private let notifiedAt: ContinuousClock.Instant
    private var line: String

    init?(notifiedAt: ContinuousClock.Instant) {
        if !FileManager.default.fileExists(atPath: Self.path) { return nil }
        self.notifiedAt = notifiedAt
        line = "\(Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).time(includingFractionalSeconds: true))) window detection:"
    }

    func mark(_ stage: String) {
        let elapsed = (ContinuousClock.now - notifiedAt).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        line += " \(stage) +\((ms * 100).rounded() / 100)ms;"
    }

    func flush() {
        guard let handle = FileHandle(forWritingAtPath: Self.path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
