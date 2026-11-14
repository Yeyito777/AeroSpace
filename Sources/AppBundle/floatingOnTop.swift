import AppKit
import Common

// Fork: `floating-windows-on-top`. macOS orders windows by app activation: focusing or clicking a tiling window brings
// it in front of the floating windows that overlap it. Only a window's owner can change its window level, and SIP keeps
// AeroSpace from injecting into the Dock (yabai's scripting addition), so the floating windows can't be pinned to a
// higher level. Instead, whenever a tiling window is in front of a floating window it overlaps, the floating windows are
// raised again: an app may order its windows in front of other apps' windows only while it's active, so each one's app
// is activated for the raise, and then the focused window's app gets the keyboard back without bringing its windows
// forward. AeroSpace focuses tiling windows without raising them in the first place (see MacWindow.nativeFocus), so the
// raise mostly runs after clicks

private let clock = ContinuousClock()

/// How long native focus changes to the raised windows' apps are taken for AeroSpace's own after a raise
private let raiseFocusProtection: Duration = .milliseconds(300)
/// A raise that didn't fix the order isn't retried for the same windows for this long
private let failedRaiseBackoff: Duration = .seconds(2)

struct StackedWindow: Equatable {
    let windowId: UInt32
    let frame: CGRect
}

/// The floating windows to raise, back to front, so that no tiling window is in front of a floating window it overlaps.
/// `stack` is front to back. Raising a floating window puts it in front of the floating windows that were in front of
/// it, so those are raised after it, which keeps the floating windows' own order
func floatingWindowsToRaise(stack: [StackedWindow], floating: Set<UInt32>, tiling: Set<UInt32>) -> [UInt32] {
    var lowestCovered: Int? = nil
    for (index, window) in stack.enumerated() where floating.contains(window.windowId) {
        let isCovered = stack[..<index].contains { other in
            tiling.contains(other.windowId) && overlapArea(other.frame, window.frame) > 1
        }
        if isCovered { lowestCovered = index }
    }
    guard let lowestCovered else { return [] }
    return stack[...lowestCovered].filter { floating.contains($0.windowId) }.map(\.windowId).reversed()
}

private func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let intersection = a.intersection(b)
    return intersection.isNull ? 0 : intersection.width * intersection.height
}

@MainActor private var raiseTask: Task<(), Never>? = nil
@MainActor private var raisingAppPids: Set<pid_t> = []
@MainActor private var raiseProtectionEnd: ContinuousClock.Instant? = nil
@MainActor private var failedRaise: (windowIds: [UInt32], at: ContinuousClock.Instant)? = nil

/// Whether a native focus change is AeroSpace's raise of floating windows rather than user intent. See updateFocusCache
@MainActor func isNativeFocusFromRaisingFloatingWindows(_ nativeFocused: Window) -> Bool {
    guard raiseTask != nil || raiseProtectionEnd.map({ clock.now < $0 }) == true else { return false }
    return raisingAppPids.contains(nativeFocused.app.pid) && nativeFocused.windowId != focus.windowOrNil?.windowId
}

/// Whether focusing the tiling window mustn't raise it: its visible workspace has floating windows. See
/// MacWindow.nativeFocus
@MainActor func shouldFocusWithoutRaise(_ window: Window) -> Bool {
    guard config.floatingWindowsOnTop, window.parent is TilingContainer, let workspace = window.nodeWorkspace,
          workspace.isVisible, !workspace.floatingWindows.isEmpty
    else { return false }
    return true
}

/// Runs after every complete refresh
@MainActor func raiseFloatingWindowsIfCovered() {
    guard config.floatingWindowsOnTop, !serverArgs.isReadOnly, !isUnitTest, raiseTask == nil else { return }
    // A drag (text selection, window move) must not lose its app. The mouse up refreshes again
    if NSEvent.pressedMouseButtons != 0 { return }
    let visibleWorkspaces = Workspace.all.filter(\.isVisible)
    let floating = Set(visibleWorkspaces.flatMap(\.floatingWindows).map(\.windowId))
    if floating.isEmpty { return }
    let tiling = Set(visibleWorkspaces.flatMap { $0.rootTilingContainer.allLeafWindowsRecursive }.map(\.windowId))
    guard let onScreen = onScreenWindowStack() else { return }
    // An open menu closes when its app is deactivated
    if onScreen.isMenuOpen { return }
    let windowIds = floatingWindowsToRaise(stack: onScreen.stack, floating: floating, tiling: tiling)
    if windowIds.isEmpty { return }
    if let failedRaise, failedRaise.windowIds == windowIds, clock.now < failedRaise.at.advanced(by: failedRaiseBackoff) {
        return
    }
    // The keyboard goes back to the focused window. Only if it has it: a utility popup (Raycast, Spotlight) or the
    // focus sink of an empty workspace keeps it
    guard let focused = focus.windowOrNil as? MacWindow,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == focused.app.pid
    else { return }
    let windows = windowIds.compactMap { Window.get(byId: $0) as? MacWindow }
    raisingAppPids = Set(windows.map(\.app.pid))
    FocusTrace.log("raising floating windows \(windowIds) over tiling windows, focus \(focused.traceDescription)")
    raiseTask = Task.startUnstructured { @MainActor in
        await raise(windows)
        // The focus may have changed meanwhile
        let target = (focus.windowOrNil as? MacWindow) ?? focused
        let restored = setFrontProcess(pid: target.app.pid, windowId: target.windowId, mode: cpsUserGenerated | cpsNoWindows) &&
            makeKeyWindowWithoutRaise(pid: target.app.pid, windowId: target.windowId)
        raiseProtectionEnd = clock.now.advanced(by: raiseFocusProtection)
        raiseTask = nil
        let stillCovered = onScreenWindowStack().map {
            floatingWindowsToRaise(stack: $0.stack, floating: floating, tiling: tiling)
        } ?? []
        if stillCovered.isEmpty {
            failedRaise = nil
        } else {
            failedRaise = (windowIds, clock.now)
        }
        FocusTrace.log("  raised; keyboard back to \(target.traceDescription) (\(restored ? "ok" : "failed"))" +
            (stillCovered.isEmpty ? "" : ", still covered: \(stillCovered)"))
        // Reconcile a native focus change that the protection hid, e.g. a click right after the raise
        try? await Task.sleep(for: raiseFocusProtection)
        scheduleCancellableCompleteRefreshSession(.floatingWindowsRaised)
    }
}

@MainActor
private func raise(_ windows: [MacWindow]) async {
    var activePid: pid_t? = nil
    for window in windows {
        let pid = window.app.pid
        if pid != activePid {
            _ = setFrontProcess(pid: pid, windowId: window.windowId, mode: cpsUserGenerated | cpsNoWindows)
            activePid = pid
        }
        try? await window.macApp.raiseAxWindow(window.windowId)
    }
}

private struct OnScreenWindowStack {
    /// Front to back, normal window level only
    var stack: [StackedWindow] = []
    var isMenuOpen = false
}

private let popUpMenuWindowLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

private func onScreenWindowStack() -> OnScreenWindowStack? {
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    guard let windows = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [NSDictionary] else { return nil }
    var result = OnScreenWindowStack()
    for window in windows {
        guard let layer = (window[kCGWindowLayer] as? NSNumber)?.intValue else { continue }
        if layer == popUpMenuWindowLevel { result.isMenuOpen = true }
        guard layer == 0,
              let windowId = (window[kCGWindowNumber] as? NSNumber)?.uint32Value,
              let bounds = window[kCGWindowBounds],
              let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
        else { continue }
        result.stack.append(StackedWindow(windowId: windowId, frame: frame))
    }
    return result
}
