import AppKit
import Common

// macOS 14 made app activation cooperative: an app that isn't active may activate itself only if the active app
// yields to it or the user just interacted with it. AeroSpace activates itself (it has no windows) to own the keyboard
// focus while the focused workspace is empty (see syncFocusToMacOs), and macOS refuses when the active app is the one
// the user last typed in, e.g. the app macOS activated after the focused window closed. The keystrokes then go to a
// window of an invisible workspace.
//
// The window server's front process call (SkyLight, private) isn't subject to cooperative activation. yabai uses it to
// focus windows. It's used only after macOS refused the public activation. Both symbols are looked up at runtime

private typealias SetFrontProcessWithOptions = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
private typealias GetProcessForPid = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

private let setFrontProcessWithOptions: SetFrontProcessWithOptions? = {
    guard let skyLight = unsafe dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let symbol = unsafe dlsym(skyLight, "_SLPSSetFrontProcessWithOptions")
    else { return nil }
    return unsafe unsafeBitCast(symbol, to: SetFrontProcessWithOptions.self)
}()

private let getProcessForPid: GetProcessForPid? = {
    // RTLD_DEFAULT. GetProcessForPID is deprecated, but it's the only way from a pid to the ProcessSerialNumber
    guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil }
    return unsafe unsafeBitCast(symbol, to: GetProcessForPid.self)
}()

/// CPS (Core Process Services) modes of _SLPSSetFrontProcessWithOptions
private let cpsUserGenerated: UInt32 = 0x200
private let cpsNoWindows: UInt32 = 0x400

/// How long macOS gets to honor the cooperative activation before AeroSpace forces it. Activation takes ~10 ms
private let cooperativeActivationGrace: Duration = .milliseconds(50)
@MainActor private var focusSinkCheck: Task<(), Never>? = nil

/// Makes AeroSpace the active app, even when macOS's cooperative activation refuses it
@MainActor
func activateAeroSpaceAsFocusSink() {
    NSApp.activate(ignoringOtherApps: true)
    let workspaceName = focus.workspace.name
    focusSinkCheck?.cancel()
    focusSinkCheck = Task.startUnstructured { @MainActor in
        try? await Task.sleep(for: cooperativeActivationGrace)
        if Task.isCancelled { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard shouldForceFocusSink(
            frontmostAppPid: frontmost?.processIdentifier,
            isFrontmostAppRegular: frontmost?.activationPolicy == .regular,
            isFocusedWorkspaceEmpty: focus.windowOrNil == nil,
            focusedWorkspaceName: focus.workspace.name,
            requestedWorkspaceName: workspaceName,
        ) else { return }
        let refusedBy = frontmostAppTraceDescription
        let forced = setFrontProcess(pid: myPid, mode: cpsUserGenerated | cpsNoWindows)
        FocusTrace.log("macOS refused to activate AeroSpace (frontmost \(refusedBy)): front process call \(forced ? "made" : "failed")")
        if forced {
            try? await Task.sleep(for: cooperativeActivationGrace)
            FocusTrace.log("  frontmost after forcing: \(frontmostAppTraceDescription)")
        }
    }
}

/// Whether macOS refused the focus sink activation and it's still wanted. A utility popup (Raycast, Spotlight) that
/// the user opened meanwhile keeps the focus
func shouldForceFocusSink(
    frontmostAppPid: pid_t?,
    isFrontmostAppRegular: Bool,
    isFocusedWorkspaceEmpty: Bool,
    focusedWorkspaceName: String,
    requestedWorkspaceName: String,
) -> Bool {
    guard let frontmostAppPid, frontmostAppPid != myPid, isFrontmostAppRegular else { return false }
    return isFocusedWorkspaceEmpty && focusedWorkspaceName == requestedWorkspaceName
}

/// Returns false if the call is unavailable or failed
@MainActor
private func setFrontProcess(pid: pid_t, mode: UInt32) -> Bool {
    if serverArgs.isReadOnly || isUnitTest { return false }
    guard let setFrontProcessWithOptions = unsafe setFrontProcessWithOptions, let getProcessForPid = unsafe getProcessForPid else { return false }
    var psn = ProcessSerialNumber()
    guard unsafe getProcessForPid(pid, &psn) == noErr else { return false }
    return unsafe setFrontProcessWithOptions(&psn, 0, mode) == 0
}
