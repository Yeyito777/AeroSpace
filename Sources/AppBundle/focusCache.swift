import AppKit
import Common

private let clock = ContinuousClock()

struct NativeFocusRaceProtection {
    // macOS chooses a replacement focused window asynchronously after a close,
    // or once the app quits, which can take a while after its last window
    // closed. Ignore the cross-workspace fallout of that choice. The protection
    // ends early once AeroSpace holds the native focus or the native focus is
    // on the closed window's workspace: then macOS has nothing left to replace.
    static let closeProtectionDuration: Duration = .seconds(1)
    // App activation can arrive just before the window-created notification.
    // Give the new window time to be registered on the current workspace.
    static let appActivationGraceDuration: Duration = .milliseconds(150)
    // Launch Services and launchers such as Raycast can emit delayed app
    // activations well after a new window is visible.  An explicit workspace
    // command is newer user intent and must win over that startup fallout.
    static let workspaceSwitchProtectionDuration: Duration = .seconds(3)

    private struct ProtectedClose {
        let workspaceName: String
        let expiresAt: ContinuousClock.Instant
    }

    private struct AppActivation {
        let appPid: Int32
        let expiresAt: ContinuousClock.Instant
    }

    private struct ProtectedWorkspaceSwitch {
        let workspaceName: String
        let expiresAt: ContinuousClock.Instant
    }

    private var protectedClose: ProtectedClose?
    private var appActivation: AppActivation?
    private var protectedWorkspaceSwitch: ProtectedWorkspaceSwitch?

    mutating func recordWindowClose(
        workspaceName: String,
        now: ContinuousClock.Instant = clock.now,
    ) {
        protectedClose = ProtectedClose(
            workspaceName: workspaceName,
            expiresAt: now.advanced(by: Self.closeProtectionDuration),
        )
    }

    mutating func clearWindowClose() {
        protectedClose = nil
    }

    mutating func recordAppActivation(
        appPid: Int32,
        now: ContinuousClock.Instant = clock.now,
    ) {
        appActivation = AppActivation(
            appPid: appPid,
            expiresAt: now.advanced(by: Self.appActivationGraceDuration),
        )
    }

    mutating func clearAppActivation(appPid: Int32) {
        if appActivation?.appPid == appPid {
            appActivation = nil
        }
    }

    mutating func recordWorkspaceSwitch(
        workspaceName: String,
        now: ContinuousClock.Instant = clock.now,
    ) {
        protectedWorkspaceSwitch = ProtectedWorkspaceSwitch(
            workspaceName: workspaceName,
            expiresAt: now.advanced(by: Self.workspaceSwitchProtectionDuration),
        )
    }

    mutating func clearWorkspaceSwitch() {
        protectedWorkspaceSwitch = nil
    }

    func shouldSuppressAfterWorkspaceSwitch(
        currentWorkspaceName: String,
        nativeWorkspaceName: String,
        now: ContinuousClock.Instant = clock.now,
    ) -> Bool {
        guard let protectedWorkspaceSwitch,
              now < protectedWorkspaceSwitch.expiresAt
        else { return false }
        return protectedWorkspaceSwitch.workspaceName == currentWorkspaceName &&
            nativeWorkspaceName != currentWorkspaceName
    }

    func shouldSuppressAfterClose(
        currentWorkspaceName: String,
        nativeWorkspaceName: String,
        now: ContinuousClock.Instant = clock.now,
    ) -> Bool {
        guard let protectedClose, now < protectedClose.expiresAt else { return false }
        return protectedClose.workspaceName == currentWorkspaceName &&
            nativeWorkspaceName != currentWorkspaceName
    }

    func appActivationDelay(
        appPid: Int32,
        currentWorkspaceName: String,
        nativeWorkspaceName: String,
        now: ContinuousClock.Instant = clock.now,
    ) -> Duration? {
        guard let appActivation,
              appActivation.appPid == appPid,
              now < appActivation.expiresAt,
              nativeWorkspaceName != currentWorkspaceName
        else { return nil }
        return now.duration(to: appActivation.expiresAt)
    }
}

/// Whether a native focus change to another workspace is macOS replacing the focused window that no longer exists.
/// The window server forgets a window as soon as it's closed (or its app quits), while AeroSpace learns about it from
/// notifications that can arrive after the replacement
func isNativeFocusFallbackForVanishedWindow(
    focusedWindowId: UInt32,
    nativeFocusedWindowId: UInt32,
    windowExists: (UInt32) -> Bool,
) -> Bool {
    focusedWindowId != nativeFocusedWindowId && !windowExists(focusedWindowId)
}

/// A native focus change to another workspace that AeroSpace declined. macOS doesn't always let AeroSpace take the
/// native focus back (cooperative app activation: e.g. not from the app the user last typed in), so the declined window
/// may stay focused. Seeing it again in a later refresh isn't new user intent. It's forgotten once the native focus
/// moves elsewhere or the user leaves the workspace
struct DeclinedNativeFocus: Equatable {
    let windowId: UInt32
    let appPid: Int32
    let workspaceName: String

    func stillHolds(nativeFocusedWindowId: UInt32?, frontmostAppPid: Int32?, currentWorkspaceName: String) -> Bool {
        if currentWorkspaceName != workspaceName { return false }
        // AX may fail to report the focused window of an app that is still frontmost
        return nativeFocusedWindowId.map { $0 == windowId } ?? (frontmostAppPid == appPid)
    }
}

/// The workspace that AeroSpace has just left by following the native focus. See MacWindow.garbageCollect
@MainActor private var workspaceLeftByFollowingNativeFocus: (name: String, date: Date)? = nil

/// Whether AeroSpace left the workspace by following the native focus less than a second ago, probably macOS's
/// replacement for a window of that workspace that is dying (and that AeroSpace failed to tell apart). Leaving it
/// with a command (e.g. right after typing `exit` in the shell of its last window) isn't
@MainActor func wasLeftByFollowingNativeFocusRecently(_ workspace: Workspace) -> Bool {
    guard let left = workspaceLeftByFollowingNativeFocus else { return false }
    return left.name == workspace.name && left.date.distance(to: .now) < 1
}

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil
@MainActor private var declinedNativeFocus: DeclinedNativeFocus? = nil
@MainActor private var raceProtection = NativeFocusRaceProtection()
@MainActor private var deferredNativeFocusTask: Task<(), Never>? = nil

@MainActor
func protectFocusAfterWindowClose(workspaceName: String) {
    raceProtection.recordWindowClose(workspaceName: workspaceName)
}

@MainActor
func cancelFocusProtectionAfterWindowClose() {
    raceProtection.clearWindowClose()
}

@MainActor
func noteNativeAppActivation(appPid: Int32) {
    raceProtection.recordAppActivation(appPid: appPid)
}

@MainActor
func protectFocusAfterWorkspaceSwitch(workspaceName: String) {
    raceProtection.recordWorkspaceSwitch(workspaceName: workspaceName)
}

@MainActor
func cancelFocusProtectionAfterWorkspaceSwitch() {
    raceProtection.clearWorkspaceSwitch()
}

@MainActor
private func scheduleDeferredNativeFocus(after delay: Duration) {
    deferredNativeFocusTask?.cancel()
    deferredNativeFocusTask = Task.startUnstructured { @MainActor in
        do {
            try await Task.sleep(for: delay)
        } catch {
            return
        }
        if !Task.isCancelled {
            scheduleCancellableCompleteRefreshSession(.deferredNativeFocus)
        }
    }
}

@MainActor
private func updateLastNativeFocusedWindow(_ window: Window?) {
    (window as? MacWindow)?.macApp.lastNativeFocusedWindowId = window?.windowId
}

@MainActor
private func reassertIntendedNativeFocus() {
    deferredNativeFocusTask?.cancel()
    let intendedFocus = focus
    syncFocusToMacOs(intendedFocus)
    lastKnownNativeFocusedWindowId = intendedFocus.windowOrNil?.windowId
}

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if let declined = declinedNativeFocus, !declined.stillHolds(
        nativeFocusedWindowId: nativeFocused?.windowId,
        frontmostAppPid: isUnitTest ? nil : NSWorkspace.shared.frontmostApplication?.processIdentifier,
        currentWorkspaceName: focus.workspace.name,
    ) {
        declinedNativeFocus = nil
    }
    if nativeFocused == nil && !isUnitTest && NSWorkspace.shared.frontmostApplication?.processIdentifier == myPid {
        raceProtection.clearWindowClose() // AeroSpace holds the native focus
    }
    guard nativeFocused?.windowId != lastKnownNativeFocusedWindowId else {
        updateLastNativeFocusedWindow(nativeFocused)
        return
    }

    guard let nativeFocused, let nativeWorkspace = nativeFocused.visualWorkspace else {
        deferredNativeFocusTask?.cancel()
        lastKnownNativeFocusedWindowId = nil
        updateLastNativeFocusedWindow(nil)
        return
    }

    let currentWorkspaceName = focus.workspace.name
    let nativeWorkspaceName = nativeWorkspace.name
    let appPid = nativeFocused.app.pid
    FocusTrace.log("native focus \(nativeFocused.traceDescription), focus \(focus.traceDescription)")

    let decline = DeclinedNativeFocus(windowId: nativeFocused.windowId, appPid: appPid, workspaceName: currentWorkspaceName)
    if nativeWorkspaceName == currentWorkspaceName {
        raceProtection.clearAppActivation(appPid: appPid)
        raceProtection.clearWindowClose()
    } else if declinedNativeFocus == decline {
        FocusTrace.log("  suppressed: still the focus that was declined")
        reassertIntendedNativeFocus()
        return
    } else if let vanished = focus.windowOrNil as? MacWindow,
              isNativeFocusFallbackForVanishedWindow(
                  focusedWindowId: vanished.windowId,
                  nativeFocusedWindowId: nativeFocused.windowId,
                  windowExists: windowServerHasWindow,
              )
    {
        // macOS activated another app because the focused window was closed or its app quit, and it did so
        // before AeroSpace learned that the window is gone. The replacement isn't user intent. The timed
        // protections below can't cover it: the app may take any time to quit
        FocusTrace.log("  focused window \(vanished.windowId) is gone: macOS replacement, collecting it")
        vanished.garbageCollect(skipClosedWindowsCache: false)
        declinedNativeFocus = decline
        reassertIntendedNativeFocus()
        return
    } else if raceProtection.shouldSuppressAfterWorkspaceSwitch(
        currentWorkspaceName: currentWorkspaceName,
        nativeWorkspaceName: nativeWorkspaceName,
    ) {
        FocusTrace.log("  suppressed: workspace switch protection")
        declinedNativeFocus = decline
        reassertIntendedNativeFocus()
        return
    } else if raceProtection.shouldSuppressAfterClose(
        currentWorkspaceName: currentWorkspaceName,
        nativeWorkspaceName: nativeWorkspaceName,
    ) {
        // Suppression must also repair native focus. Merely ignoring macOS's
        // replacement leaves that hidden-workspace app frontmost, and a later
        // refresh can mistake the stale replacement for user intent.
        FocusTrace.log("  suppressed: close protection")
        declinedNativeFocus = decline
        reassertIntendedNativeFocus()
        return
    } else if let delay = raceProtection.appActivationDelay(
        appPid: appPid,
        currentWorkspaceName: currentWorkspaceName,
        nativeWorkspaceName: nativeWorkspaceName,
    ) {
        FocusTrace.log("  deferred: app activation grace \(delay.ms)ms")
        scheduleDeferredNativeFocus(after: delay)
        updateLastNativeFocusedWindow(nativeFocused)
        return
    }

    if nativeWorkspaceName != currentWorkspaceName {
        FocusTrace.log("  following native focus to ws \(nativeWorkspaceName)")
        workspaceLeftByFollowingNativeFocus = (currentWorkspaceName, .now)
    }
    deferredNativeFocusTask?.cancel()
    _ = nativeFocused.focusWindow()
    lastKnownNativeFocusedWindowId = nativeFocused.windowId
    updateLastNativeFocusedWindow(nativeFocused)
}
