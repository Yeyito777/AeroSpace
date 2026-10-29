@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class SpawnCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        let args = SpawnCmdArgs(rawArgs: []).copy(\.workspace, .parse("bg").getOrDie())
        testParseSingleCommandSucc("spawn --workspace bg -- app --flag x", args.copy(\.command, ["app", "--flag", "x"]))
        testParseSingleCommandSucc("spawn --workspace bg --pid 42", args.copy(\.pid, 42))
        assertEquals(parseCommand("spawn -- app").errorOrNil, "Mandatory option is not specified (--workspace)")
        assertEquals(
            parseCommand("spawn --workspace bg").errorOrNil,
            "Either '-- <command>' or '--pid <pid>' must be specified, but not both",
        )
        assertEquals(
            parseCommand("spawn --workspace bg --pid 42 -- app").errorOrNil,
            "Either '-- <command>' or '--pid <pid>' must be specified, but not both",
        )
        assertEquals(parseCommand("spawn --workspace bg app").errorOrNil, "ERROR: Expected: --. Got: 'app'\nERROR: Unknown argument 'app'")
        assertEquals(parseCommand("spawn --workspace bg --").errorOrNil, "ERROR: '--' must be followed by '<command>'")
    }

    func testWindowsOfDescendantProcessesGoToTheWorkspace() throws {
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { child.terminate() }

        XCTAssertNil(spawnWorkspaceName(pid: child.processIdentifier))
        XCTAssertTrue(registerSpawnedProcess(pid: getpid(), workspaceName: "bg"))
        assertEquals(spawnWorkspaceName(pid: getpid()), "bg")
        assertEquals(spawnWorkspaceName(pid: child.processIdentifier), "bg")
        XCTAssertNil(spawnWorkspaceName(pid: 1))
    }

    func testDeadProcess() async throws {
        let child = Process()
        child.executableURL = URL(filePath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let result = await parseCommand("spawn --workspace bg --pid \(child.processIdentifier)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["No process with pid \(child.processIdentifier)"])
    }

    func testServerDoesNotRunCommands() async {
        let result = await parseCommand("spawn --workspace bg -- app").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
    }

    func testSpawnedProcessDoesNotTakeTheFocusToItsWorkspace() {
        let current = Workspace.get(byName: "spawn-current")
        let background = Workspace.get(byName: "spawn-background")
        let focused = TestWindow.new(id: 9301, parent: current.rootTilingContainer)
        _ = focused.focusWindow()
        let spawned = TestWindow.new(id: 9302, parent: background.rootTilingContainer)
        XCTAssertTrue(registerSpawnedProcess(pid: spawned.app.pid, workspaceName: background.name))

        updateFocusCache(spawned) // The spawned app activated itself

        assertEquals(focus.workspace, current)
        assertEquals(focus.windowOrNil, focused)
    }
}
