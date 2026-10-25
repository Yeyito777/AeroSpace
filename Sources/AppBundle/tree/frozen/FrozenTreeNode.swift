import AppKit
import Common

enum FrozenTreeNode: Sendable, Codable, Equatable {
    case container(FrozenContainer)
    case window(FrozenWindow)

    private enum CodingKeys: String, CodingKey { case container, window }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let window = try container.decodeIfPresent(FrozenWindow.self, forKey: .window) {
            self = .window(window)
        } else {
            self = .container(try container.decode(FrozenContainer.self, forKey: .container))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case .container(let c): try container.encode(c, forKey: .container)
            case .window(let w): try container.encode(w, forKey: .window)
        }
    }
}

struct FrozenContainer: Sendable, Codable, Equatable {
    let children: [FrozenTreeNode]
    let layout: Layout
    let orientation: Orientation
    let weight: CGFloat

    @MainActor init(_ container: TilingContainer) {
        children = container.children.map {
            switch $0.nodeCases {
                case .window(let w): .window(FrozenWindow(w))
                case .tilingContainer(let c): .container(FrozenContainer(c))
                case .workspace,
                     .floatingWindowsContainer,
                     .macosMinimizedWindowsContainer,
                     .macosHiddenAppsWindowsContainer,
                     .macosFullscreenWindowsContainer,
                     .macosPopupWindowsContainer:
                    illegalChildParentRelation(child: $0, parent: container)
            }
        }
        layout = container.layout
        orientation = container.orientation
        weight = getWeightOrNil(container) ?? 1
    }

    init(children: [FrozenTreeNode], layout: Layout, orientation: Orientation, weight: CGFloat) {
        self.children = children
        self.layout = layout
        self.orientation = orientation
        self.weight = weight
    }
}

extension FrozenContainer {
    var allWindowsRecursive: [FrozenWindow] {
        children.flatMap { child -> [FrozenWindow] in
            switch child {
                case .window(let w): [w]
                case .container(let c): c.allWindowsRecursive
            }
        }
    }

    /// Empty containers are kept. Normalization removes them
    func filterWindows(_ isIncluded: (FrozenWindow) -> Bool) -> FrozenContainer {
        FrozenContainer(
            children: children.compactMap { child -> FrozenTreeNode? in
                switch child {
                    case .window(let w): isIncluded(w) ? child : nil
                    case .container(let c): .container(c.filterWindows(isIncluded))
                }
            },
            layout: layout,
            orientation: orientation,
            weight: weight,
        )
    }
}

/// Identifies the process that owned a window. Window ids are only meaningful while the same app process lives
struct FrozenApp: Sendable, Codable, Equatable {
    let pid: Int32
    let bundleId: String?
    /// NSRunningApplication.launchDate. Protects against pid reuse
    let launchTime: Double?
}

struct FrozenWindow: Sendable, Codable, Equatable {
    let id: UInt32
    let weight: CGFloat
    // The rest is only needed to restore windows after AeroSpace restart (see worldSnapshot.swift)
    var app: FrozenApp? = nil
    /// The container kind for macOS native fullscreen and hidden app windows
    var macosParentKind: NonLeafTreeNodeKind? = nil
    /// LayoutReason.macos(prevParentKind:)
    var macosPrevParentKind: NonLeafTreeNodeKind? = nil
    /// The position to restore once a window hidden in the corner is shown again. See MacWindow.hideInCorner
    var unhiddenProportionalPosition: CGPoint? = nil

    @MainActor init(_ window: Window) {
        id = window.windowId
        weight = getWeightOrNil(window) ?? 1
        app = FrozenApp(
            pid: window.app.pid,
            bundleId: window.app.rawAppBundleId,
            launchTime: (window as? MacWindow)?.macApp.nsApp.launchDate?.timeIntervalSince1970,
        )
        switch window.parent?.kind {
            case .macosFullscreenWindowsContainer: macosParentKind = .macosFullscreenWindowsContainer
            case .macosHiddenAppsWindowsContainer: macosParentKind = .macosHiddenAppsWindowsContainer
            default: macosParentKind = nil
        }
        if case .macos(let prevParentKind) = window.layoutReason {
            macosPrevParentKind = prevParentKind
        }
        unhiddenProportionalPosition = (window as? MacWindow)?.unhiddenProportionalPosition
    }

    init(id: UInt32, weight: CGFloat, app: FrozenApp?) {
        self.id = id
        self.weight = weight
        self.app = app
    }
}

@MainActor private func getWeightOrNil(_ node: TreeNode) -> CGFloat? {
    ((node.parent as? TilingContainer)?.orientation).map { node.getWeight($0) }
}
