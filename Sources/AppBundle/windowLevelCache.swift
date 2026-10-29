import CoreGraphics
import Foundation

@MainActor
private var cache: [UInt32: MacOsWindowLevel] = [:]

@MainActor
func getWindowLevel(for windowId: UInt32) -> MacOsWindowLevel? {
    if let existing = cache[windowId] { return existing }

    var result: [UInt32: MacOsWindowLevel] = [:]
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] else { return nil }
    for elem in cfArray {
        let dict = elem as NSDictionary

        guard let _windowLayer = dict[kCGWindowLayer] else { continue }
        let windowLayer = ((_windowLayer as! CFNumber) as NSNumber).intValue

        guard let _windowId = dict[kCGWindowNumber] else { continue }
        let windowId = ((_windowId as! CFNumber) as NSNumber).uint32Value

        result[windowId] = .new(windowLevel: windowLayer)
    }
    cache = result
    return result[windowId]
}

/// The window server's description of the window, or nil if the window doesn't exist. From any thread
func getWindowServerDescription(of windowId: UInt32) -> NSDictionary? {
    // The array must hold the CGWindowID values themselves. An array of NSNumbers matches no window
    var value = unsafe UnsafeRawPointer(bitPattern: UInt(windowId))
    guard let ids = unsafe CFArrayCreate(nil, &value, 1, nil) else { return nil }
    return (CGWindowListCreateDescriptionFromArray(ids) as? [NSDictionary])?.first
}

/// Whether the window server still has the window. A window that is closed, or whose app quit, is gone at once,
/// while AeroSpace learns about it from asynchronous notifications. Hidden and minimized windows still exist
func windowServerHasWindow(_ windowId: UInt32) -> Bool {
    getWindowServerDescription(of: windowId) != nil
}

/// Same as getWindowLevel, for one window, from any thread
func getWindowLevelOffMainThread(for windowId: UInt32) -> MacOsWindowLevel? {
    guard let info = getWindowServerDescription(of: windowId),
          (info[kCGWindowIsOnscreen] as? Bool) == true, // getWindowLevel only knows on-screen windows
          let layer = info[kCGWindowLayer] as? NSNumber
    else { return nil }
    return .new(windowLevel: layer.intValue)
}

enum MacOsWindowLevel: Sendable, Equatable {
    case normalWindow
    case alwaysOnTopWindow
    case unknown(windowLevel: Int)

    static func new(windowLevel: Int) -> MacOsWindowLevel {
        switch windowLevel {
            case 0: .normalWindow
            case 3: .alwaysOnTopWindow
            default: .unknown(windowLevel: windowLevel)
        }
    }

    static func fromJson(_ json: Json) -> MacOsWindowLevel? {
        switch json {
            case .string("normalWindow"): .normalWindow
            case .string("alwaysOnTopWindow"): .alwaysOnTopWindow
            case .int(let int): .new(windowLevel: Int(exactly: int).orDie())
            default: nil
        }
    }

    func toJson() -> Json {
        switch self {
            case .normalWindow: .string("normalWindow")
            case .alwaysOnTopWindow: .string("alwaysOnTopWindow")
            case .unknown(let layerNumber): .int(layerNumber)
        }
    }
}
