import AppKit
import Common
import Security

struct RestartCommand: Command {
    let args: RestartCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        switch await restartServer(installing: args.installBundlePath.map { URL(filePath: $0) }) {
            case nil: .succ
            case let error?: .fail(io.err(error))
        }
    }
}

private let handoverReadyTimeout: Duration = .seconds(10)
private let oldInstanceExitTimeout: Duration = .seconds(15)

private func handoverReadyFile(oldPid: pid_t) -> URL {
    PersistentWorld.url.deletingLastPathComponent().appending(path: "restart-handover-\(oldPid).ready")
}

@MainActor private var isRestarting = false

/// Restart protocol. The new instance is started before the old one exits, so that a failed launch never leaves the
/// user without a window manager:
/// 0. With `--install`, the running bundle is replaced (the previous one is kept aside until the restart succeeds)
/// 1. The old instance saves the world (persistentWorld.swift) and launches a new instance of the bundle from disk with
///    `--restart-handover <old pid>`
/// 2. The new instance checks that it's trusted for the accessibility API (it doesn't prompt), reports readiness
///    with a file and waits for the old instance to exit. It doesn't touch windows, monitors or the socket until then
/// 3. The old instance saves the world one last time and exits without the termination handler, so that windows
///    of invisible workspaces stay hidden in the corners. The new instance restores the world
///
/// If the new instance doesn't become ready in time, it's killed (it hasn't done anything yet), the previous bundle
/// is put back and the old instance keeps running. Returns an error message on failure
@MainActor
func restartServer(installing newBundle: URL?) async -> String? {
    if serverArgs.isReadOnly { return "Can't restart a read-only server" }
    // Two new instances would both take over once this one exits
    if isRestarting { return "Restart is already in progress" }
    let bundleUrl = Bundle.main.bundleURL
    if bundleUrl.pathExtension != "app" { return "Can't restart \(bundleUrl.path): not an app bundle" }
    isRestarting = true
    defer { isRestarting = false } // Only matters on failure. On success, the process exits

    var previousBundle: URL? = nil
    if let newBundle {
        switch installBundle(newBundle, replacing: bundleUrl) {
            case .success(let backup): previousBundle = backup
            case .failure(let error): return error
        }
    }
    func failure(_ error: String) -> String {
        guard let previousBundle else { return error }
        return switch Result(catching: { try FileManager.default.replaceItemAt(bundleUrl, withItemAt: previousBundle) }) {
            case .success: "\(error)\nThe previous \(bundleUrl.path) was put back"
            case .failure(let e): "\(error)\nCan't put the previous bundle back from \(previousBundle.path): \(e.localizedDescription)"
        }
    }

    if let error = savePersistentWorldNow() { return failure(error) }
    let readyFile = handoverReadyFile(oldPid: myPid)
    try? FileManager.default.removeItem(at: readyFile)
    var arguments = ["--restart-handover", String(myPid)]
    if let configLocation = serverArgs.configLocation { arguments += ["--config-path", configLocation] }
    let newPid: pid_t
    switch await launchNewInstance(bundleUrl, arguments) {
        case .success(let pid): newPid = pid
        case .failure(let error): return failure("Can't launch \(bundleUrl.path): \(error.localizedDescription)")
    }

    let clock = ContinuousClock()
    let deadline = clock.now + handoverReadyTimeout
    while !FileManager.default.fileExists(atPath: readyFile.path) {
        if NSRunningApplication(processIdentifier: newPid)?.isTerminated != false {
            return failure(
                "The new AeroSpace instance (pid \(newPid)) exited before taking over. " +
                    "Is \(bundleUrl.path) allowed to use the accessibility API? " +
                    "(System Settings > Privacy & Security > Accessibility)",
            )
        }
        if clock.now > deadline {
            kill(newPid, SIGKILL)
            return failure("The new AeroSpace instance (pid \(newPid)) didn't take over in time. It was stopped")
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    try? FileManager.default.removeItem(at: readyFile)

    if let error = savePersistentWorldNow() {
        kill(newPid, SIGKILL)
        return failure(error)
    }
    isPersistentWorldSavingEnabled = false // The new instance owns the saved world from now on
    if let previousBundle { try? FileManager.default.removeItem(at: previousBundle) }
    Task.startUnstructured { @MainActor in
        try? await Task.sleep(for: .milliseconds(100)) // Let the server answer the client
        // Don't run the termination handler: it would show windows that are hidden in the corners
        exit(EXIT_CODE_ZERO)
    }
    return nil
}

/// Replaces `destination` with a copy of `source`, if `source` satisfies the code signing requirement of the running
/// app (so that the accessibility permission applies to it too). Returns where the previous bundle was moved
private func installBundle(_ source: URL, replacing destination: URL) -> Result<URL, String> {
    let source = source.standardizedFileURL
    if source.path == destination.standardizedFileURL.path { return .failure("\(source.path) is the running bundle") }
    if let error = checkSignatureSatisfiesOwnRequirement(source) { return .failure(error) }
    let fileManager = FileManager.default
    let directory = destination.deletingLastPathComponent()
    let staged = directory.appending(path: ".\(destination.lastPathComponent).installing")
    let backupName = "\(destination.lastPathComponent).previous" // Not a .app, so LaunchServices ignores it
    let backup = directory.appending(path: backupName)
    do {
        try? fileManager.removeItem(at: staged)
        try? fileManager.removeItem(at: backup)
        try fileManager.copyItem(at: source, to: staged)
        if let error = checkSignatureSatisfiesOwnRequirement(staged) {
            try? fileManager.removeItem(at: staged)
            return .failure("The copy of \(source.path) is broken: \(error)")
        }
        _ = try fileManager.replaceItemAt(destination, withItemAt: staged, backupItemName: backupName, options: .withoutDeletingBackupItem)
        return .success(backup)
    } catch {
        try? fileManager.removeItem(at: staged)
        return .failure("Can't install \(source.path) to \(destination.path): \(error.localizedDescription)")
    }
}

private func checkSignatureSatisfiesOwnRequirement(_ bundle: URL) -> String? {
    var ownCode: SecCode? = nil
    var ownStaticCode: SecStaticCode? = nil
    var requirement: SecRequirement? = nil
    var staticCode: SecStaticCode? = nil
    guard unsafe SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
          unsafe SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode,
          unsafe SecCodeCopyDesignatedRequirement(ownStaticCode, [], &requirement) == errSecSuccess, let requirement
    else { return "Can't read the code signing requirement of the running AeroSpace.app" }
    guard unsafe SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
        return "\(bundle.path) isn't signed code"
    }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    let status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
    if status == errSecSuccess { return nil }
    let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    return "\(bundle.path) doesn't satisfy the code signing requirement of the running AeroSpace.app " +
        "(the accessibility permission wouldn't apply to it): \(message)"
}

@MainActor
private func launchNewInstance(_ bundleUrl: URL, _ arguments: [String]) async -> Result<pid_t, any Error> {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.arguments = arguments
    return await withCheckedContinuation { cont in
        NSWorkspace.shared.openApplication(at: bundleUrl, configuration: configuration) { app, error in
            if let app {
                cont.resume(returning: .success(app.processIdentifier))
            } else {
                cont.resume(returning: .failure(error ?? CocoaError(.executableLoad)))
            }
        }
    }
}

/// The new instance's side of restartServer. Called before anything else on startup
@MainActor
func takeOverFromRestartingInstance(oldPid: pid_t) async {
    // Prompting for the permission now would leave the user without a window manager until it's granted
    if !AXIsProcessTrusted() { exit(EXIT_CODE_TWO) }
    let readyFile = handoverReadyFile(oldPid: oldPid)
    do {
        try FileManager.default.createDirectory(at: readyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(String(myPid).utf8).write(to: readyFile, options: .atomic)
    } catch {
        exit(EXIT_CODE_TWO)
    }
    let clock = ContinuousClock()
    let deadline = clock.now + oldInstanceExitTimeout
    while kill(oldPid, 0) == 0 || errno == EPERM {
        if clock.now > deadline { exit(EXIT_CODE_TWO) } // Never manage windows together with another instance
        try? await Task.sleep(for: .milliseconds(10))
    }
}
