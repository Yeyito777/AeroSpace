import AppKit
import Common

/// Processes started with `aerospace spawn`. Their windows, and the windows of their descendant processes, open on the
/// requested workspace instead of the focused one, and never take the focus to it (see updateFocusCache)
private struct SpawnedProcess {
    let startTime: UInt64
    let workspaceName: String
}

@MainActor private var spawnedProcesses: [pid_t: SpawnedProcess] = [:]
/// Spawned processes without a registered window -> when to stop looking for their first window
@MainActor private var awaitingFirstWindow: [pid_t: ContinuousClock.Instant] = [:]
@MainActor private var firstWindowWatch: Task<(), Never>? = nil
private let firstWindowWatchTimeout: Duration = .seconds(30)
private let firstWindowPollInterval: Duration = .milliseconds(10)

/// Returns false if the process doesn't exist
@MainActor func registerSpawnedProcess(pid: pid_t, workspaceName: String) -> Bool {
    // Forget processes that are gone. The start time keeps a reused pid from inheriting their workspace
    spawnedProcesses = spawnedProcesses.filter { pid, process in processInfo(pid)?.startTime == process.startTime }
    awaitingFirstWindow = awaitingFirstWindow.filter { pid, _ in spawnedProcesses[pid] != nil }
    guard let info = processInfo(pid) else { return false }
    spawnedProcesses[pid] = SpawnedProcess(startTime: info.startTime, workspaceName: workspaceName)
    awaitingFirstWindow[pid] = .now + firstWindowWatchTimeout
    watchForFirstWindows()
    return true
}

/// The workspace that `aerospace spawn` requested for the windows of the process or of one of its ancestors
@MainActor func spawnWorkspaceName(pid: pid_t) -> String? {
    spawnedRoot(pid: pid).flatMap { spawnedProcesses[$0]?.workspaceName }
}

/// The workspace for a new window of the process. See MacWindow.getOrRegister
@MainActor func spawnWorkspaceForNewWindow(pid: pid_t) -> Workspace? {
    guard let root = spawnedRoot(pid: pid), let spawned = spawnedProcesses[root] else { return nil }
    awaitingFirstWindow[root] = nil
    return Workspace.get(byName: spawned.workspaceName)
}

@MainActor private func spawnedRoot(pid: pid_t) -> pid_t? {
    if spawnedProcesses.isEmpty { return nil }
    var pid = pid
    for _ in 0 ..< 32 {
        guard let info = processInfo(pid) else { return nil }
        if spawnedProcesses[pid]?.startTime == info.startTime { return pid }
        if info.parentPid <= 1 { return nil }
        pid = info.parentPid
    }
    return nil
}

/// AeroSpace subscribes to the windows of an app once it learns about the app, but AX requests to an app that is still
/// starting fail. Then AeroSpace sees its first window only on the next complete refresh, and meanwhile the window
/// stays visible where the app put it. So until the first window of a spawned process is registered, the window server
/// is polled for it, and the window detection starts as soon as it's shown
@MainActor private func watchForFirstWindows() {
    if firstWindowWatch != nil { return }
    firstWindowWatch = Task.startUnstructured { @MainActor in
        defer { firstWindowWatch = nil }
        var detectionAttempts: [UInt32: Int] = [:]
        while !awaitingFirstWindow.isEmpty {
            try? await Task.sleep(for: firstWindowPollInterval)
            let now = ContinuousClock.now
            awaitingFirstWindow = awaitingFirstWindow.filter { _, deadline in now < deadline }
            for (windowId, pid) in await onScreenWindowOwners()
                where MacWindow.allWindowsMap[windowId] == nil && detectionAttempts[windowId, default: 0] < 3
            {
                guard let root = spawnedRoot(pid: pid), awaitingFirstWindow[root] != nil,
                      let nsApp = NSRunningApplication(processIdentifier: pid),
                      (try? await MacApp.getOrRegister(nsApp)) != nil // nil until the app answers AX requests
                else { continue }
                detectionAttempts[windowId, default: 0] += 1
                await runWindowDetectionSession(.spawnedWindow, pid: pid, createdWindow: nil, notifiedAt: now)
            }
        }
    }
}

/// window id -> owner pid of the on-screen windows of the normal window level
@concurrent private func onScreenWindowOwners() async -> [UInt32: pid_t] {
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    guard let windows = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [NSDictionary] else { return [:] }
    var result: [UInt32: pid_t] = [:]
    for window in windows where (window[kCGWindowLayer] as? NSNumber)?.intValue == 0 {
        guard let windowId = window[kCGWindowNumber] as? NSNumber, let pid = window[kCGWindowOwnerPID] as? NSNumber else { continue }
        result[windowId.uint32Value] = pid.int32Value
    }
    return result
}

private func processInfo(_ pid: pid_t) -> (startTime: UInt64, parentPid: pid_t)? {
    var info = unsafe kinfo_proc()
    var size = unsafe MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    // A missing process isn't an error for sysctl: it reports an empty result
    guard unsafe sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let start = unsafe info.kp_proc.p_starttime
    return unsafe (UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec), info.kp_eproc.e_ppid)
}

@MainActor func forgetSpawnedProcessesForTests() {
    spawnedProcesses = [:]
    awaitingFirstWindow = [:]
}
