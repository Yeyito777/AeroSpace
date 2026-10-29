import AppKit
import Common

/// Opt-in log of focus decisions: which native focus AeroSpace saw, what it did about it, and why.
/// Enable: `mkdir -p ~/Library/Logs/AeroSpace && touch ~/Library/Logs/AeroSpace/focus.log`
/// Disable: delete the file
@MainActor
enum FocusTrace {
    private static let path = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/AeroSpace/focus.log").path
    private static var isEnabled = false
    private static var lastCheck: ContinuousClock.Instant? = nil

    static func log(_ message: @autoclosure () -> String) {
        let now = ContinuousClock.now
        if lastCheck.map({ now - $0 > .seconds(1) }) ?? true {
            lastCheck = now
            isEnabled = FileManager.default.fileExists(atPath: path)
        }
        if !isEnabled { return }
        let time = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).time(includingFractionalSeconds: true))
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(time) \(message())\n".utf8))
    }
}

extension Window {
    @MainActor var traceDescription: String {
        "\(windowId)(\(app.name ?? "?") pid \(app.pid) ws \(visualWorkspace?.name ?? "-"))"
    }
}

extension LiveFocus {
    @MainActor var traceDescription: String { "ws \(workspace.name) window \(windowOrNil?.traceDescription ?? "nil")" }
}

@MainActor var frontmostAppTraceDescription: String {
    let app = NSWorkspace.shared.frontmostApplication
    return "\(app?.localizedName ?? "nil") pid \(app?.processIdentifier ?? 0)"
}
