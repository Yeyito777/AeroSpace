import AppKit
import Foundation

private let raycastBundleIDs: Set<String> = [
    "com.raycast.macos",
    "com.raycast.macos.beta",
]

private let aerospacePath: String = {
    let candidates = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        ?? "/opt/homebrew/bin/aerospace"
}()

private struct FocusedWindow {
    let id: String
    let bundleID: String
    let workspace: String
}

private struct RaycastLaunchSession {
    let id = UUID()
    let workspace: String
    let originatingBundleID: String?
    var expectedBundleID: String?
}

@discardableResult
private func runAeroSpace(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: aerospacePath)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (1, "")
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func focusedWorkspace() -> String? {
    let result = runAeroSpace(["list-workspaces", "--focused"])
    guard result.status == 0 else { return nil }
    let workspace = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return workspace.isEmpty ? nil : workspace
}

private func focusedWindow() -> FocusedWindow? {
    let result = runAeroSpace([
        "list-windows", "--focused",
        "--format", "%{window-id}|%{app-bundle-id}|%{workspace}",
    ])
    guard result.status == 0 else { return nil }

    let fields = result.output
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "|", maxSplits: 2)
        .map(String.init)

    guard fields.count == 3 else { return nil }
    return FocusedWindow(id: fields[0], bundleID: fields[1], workspace: fields[2])
}

private final class RaycastWorkspaceKeeper: NSObject {
    private var lastNonRaycastBundleID: String? = {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return bundleID.flatMap { raycastBundleIDs.contains($0) ? nil : $0 }
    }()
    private var launchSession: RaycastLaunchSession?
    private var sessionExpiry: DispatchWorkItem?
    private var originatingAppReturn: DispatchWorkItem?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            let bundleID = app.bundleIdentifier
        else { return }

        if raycastBundleIDs.contains(bundleID) {
            beginRaycastSession()
            return
        }

        defer { lastNonRaycastBundleID = bundleID }
        guard let session = launchSession else { return }

        if let expectedBundleID = session.expectedBundleID,
            bundleID != expectedBundleID
        {
            return
        }

        if session.expectedBundleID == nil,
            bundleID == session.originatingBundleID
        {
            waitForActualTarget(afterReturningTo: bundleID, sessionID: session.id)
            return
        }

        finishSession(with: bundleID, session: session)
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        guard
            var session = launchSession,
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            let bundleID = app.bundleIdentifier,
            !raycastBundleIDs.contains(bundleID)
        else { return }

        session.expectedBundleID = bundleID
        launchSession = session
        originatingAppReturn?.cancel()
        originatingAppReturn = nil
    }

    private func beginRaycastSession() {
        guard let workspace = focusedWorkspace() else { return }

        sessionExpiry?.cancel()
        originatingAppReturn?.cancel()

        let session = RaycastLaunchSession(
            workspace: workspace,
            originatingBundleID: lastNonRaycastBundleID
        )
        launchSession = session

        let expiry = DispatchWorkItem { [weak self] in
            guard self?.launchSession?.id == session.id else { return }
            self?.clearSession()
        }
        sessionExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: expiry)
    }

    private func waitForActualTarget(afterReturningTo bundleID: String, sessionID: UUID) {
        originatingAppReturn?.cancel()

        let returnTimeout = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.launchSession?.id == sessionID,
                self.launchSession?.expectedBundleID == nil,
                self.lastNonRaycastBundleID == bundleID
            else { return }
            self.clearSession()
        }
        originatingAppReturn = returnTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: returnTimeout)
    }

    private func finishSession(with bundleID: String, session: RaycastLaunchSession) {
        clearSession()

        DispatchQueue.global(qos: .userInitiated).async {
            self.moveActivatedWindow(
                bundleID: bundleID,
                to: session.workspace
            )
        }
    }

    private func clearSession() {
        launchSession = nil
        sessionExpiry?.cancel()
        sessionExpiry = nil
        originatingAppReturn?.cancel()
        originatingAppReturn = nil
    }

    private func moveActivatedWindow(
        bundleID: String,
        to targetWorkspace: String
    ) {
        // Cold-started apps can become active before AeroSpace has detected a window.
        for _ in 0..<160 {
            if let window = focusedWindow(), window.bundleID == bundleID {
                if window.workspace != targetWorkspace {
                    _ = runAeroSpace([
                        "move-node-to-workspace",
                        "--focus-follows-window",
                        "--window-id", window.id,
                        targetWorkspace,
                    ])
                }

                // The activation that started this session already focused the
                // target.  Do not keep reasserting focus: an immediate workspace
                // switch is explicit user intent and must win.
                return
            }

            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

private let keeper = RaycastWorkspaceKeeper()
keeper.start()
RunLoop.main.run()
