import AppKit

extension Workspace {
    @MainActor func normalizeContainers() {
        if config.horizontalTilingOnly {
            rootTilingContainer.flattenIntoHorizontalRow()
        }
        rootTilingContainer.unbindEmptyAndAutoFlatten() // Beware! rootTilingContainer may change after this line of code
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

extension TilingContainer {
    @MainActor fileprivate func unbindEmptyAndAutoFlatten() {
        if let child = children.singleOrNil(), config.enableNormalizationFlattenContainers && (child is TilingContainer || !isRootContainer) {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent()
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            }
            if children.isEmpty && !isRootContainer {
                unbindFromParent()
            }
        }
    }
}

extension TilingContainer {
    /// Fork: `horizontal-tiling-only`. Lift every window out of nested containers into this
    /// root, in tree order, and make the root horizontal. A lifted window gets an equal share
    /// of the weight its top-level container had, so the other columns keep their sizes.
    @MainActor fileprivate func flattenIntoHorizontalRow() {
        if children.contains(where: { $0 is TilingContainer }) {
            let mru = mostRecentWindowRecursive
            for (index, child) in children.enumerated().reversed() {
                guard let nested = child as? TilingContainer else { continue }
                let windows = nested.allLeafWindowsRecursive
                let weight = nested.getWeight(orientation) / CGFloat(max(windows.count, 1))
                for (offset, window) in windows.enumerated() {
                    window.bind(to: self, adaptiveWeight: weight, index: index + offset)
                }
                nested.unbindFromParent()
            }
            mru?.markAsMostRecentChild()
        }
        forceOrientation(.h)
    }
}
