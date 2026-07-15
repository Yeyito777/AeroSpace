import AppKit
import Common

func shouldActivateFocusSinkBeforeClose(
    isFocusedWindow: Bool,
    workspaceWindowCount: Int,
) -> Bool {
    isFocusedWindow && workspaceWindowCount == 1
}

struct CloseCommand: Command {
    let args: CloseCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            return .fail(io.err("Empty workspace"))
        }
        // Access ax directly. Not cool :(
        if await args.quitIfLastWindow.andAsync({ @MainActor @Sendable in (try? await window.macAppUnsafe.getAxWindowsCount(.nonCancellable)) == 1 }) {
            let app = window.macAppUnsafe
            if shouldActivateFocusSinkBeforeClose(
                isFocusedWindow: focus.windowOrNil == window,
                workspaceWindowCount: target.workspace.allLeafWindowsRecursive.count,
            ) {
                // If the terminating app owns the only window on the active
                // virtual workspace, become the native frontmost app first.
                // Otherwise macOS activates an app from another workspace
                // while the current workspace is empty.
                NSApp.activate(ignoringOtherApps: true)
            }
            if app.nsApp.terminate() {
                for workspace in Workspace.all {
                    for window in workspace.allLeafWindowsRecursive where window.app.pid == app.pid {
                        (window as! MacWindow).garbageCollect(skipClosedWindowsCache: true)
                    }
                }
                return .succ
            } else {
                return .fail(io.err("Failed to quit '\(window.app.name ?? "Unknown app")'"))
            }
        } else {
            window.closeAxWindow()
            return .succ
        }
    }
}
