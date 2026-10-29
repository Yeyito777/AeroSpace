import AppKit
import Common

struct SpawnCommand: Command {
    let args: SpawnCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        // The CLI client runs '<command>' itself, after the server has registered its pid
        guard let pid = args.pid else {
            return .fail(io.err("The server can't run '<command>'. Use the aerospace CLI: exec-and-forget aerospace spawn ..."))
        }
        let workspaceName = args.workspace.orDie().raw
        return registerSpawnedProcess(pid: pid, workspaceName: workspaceName)
            ? .succ
            : .fail(io.err("No process with pid \(pid)"))
    }
}
