import AppKit
import Common

/// Processes started with `aerospace spawn`. Their windows, and the windows of their descendant processes, open on the
/// requested workspace instead of the focused one, and never take the focus to it (see updateFocusCache)
private struct SpawnedProcess {
    let startTime: UInt64
    let workspaceName: String
}

@MainActor private var spawnedProcesses: [pid_t: SpawnedProcess] = [:]

/// Returns false if the process doesn't exist
@MainActor func registerSpawnedProcess(pid: pid_t, workspaceName: String) -> Bool {
    // Forget processes that are gone. The start time keeps a reused pid from inheriting their workspace
    spawnedProcesses = spawnedProcesses.filter { pid, process in processInfo(pid)?.startTime == process.startTime }
    guard let info = processInfo(pid) else { return false }
    spawnedProcesses[pid] = SpawnedProcess(startTime: info.startTime, workspaceName: workspaceName)
    return true
}

/// The workspace that `aerospace spawn` requested for the windows of the process or of one of its ancestors
@MainActor func spawnWorkspaceName(pid: pid_t) -> String? {
    if spawnedProcesses.isEmpty { return nil }
    var pid = pid
    for _ in 0 ..< 32 {
        guard let info = processInfo(pid) else { return nil }
        if let spawned = spawnedProcesses[pid], spawned.startTime == info.startTime { return spawned.workspaceName }
        if info.parentPid <= 1 { return nil }
        pid = info.parentPid
    }
    return nil
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
}
