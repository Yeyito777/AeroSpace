import AppKit
import Common

// macOS 14 made app activation cooperative: an app that isn't active may activate itself only if the active app
// yields to it or the user just interacted with it. AeroSpace activates itself (it has no windows) to own the keyboard
// focus while the focused workspace is empty (see syncFocusToMacOs), and macOS refuses when the active app is the one
// the user last typed in, e.g. the app macOS activated after the focused window closed. The keystrokes then go to a
// window of an invisible workspace.
//
// The window server's front process call (SkyLight, private) isn't subject to cooperative activation. yabai uses it to
// focus windows. Both symbols are looked up at runtime: without them, only the public activation is attempted

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

/// Makes AeroSpace the active app, even when macOS's cooperative activation would refuse it
@MainActor
func activateAeroSpaceAsFocusSink() {
    NSApp.activate(ignoringOtherApps: true)
    if !setFrontProcess(pid: myPid, mode: cpsUserGenerated | cpsNoWindows) {
        FocusTrace.log("  front process call unavailable or failed; relying on cooperative activation")
    }
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
