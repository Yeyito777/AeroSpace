@testable import AppBundle
import XCTest

final class FocusCacheTest: XCTestCase {
    private let now = ContinuousClock().now

    func testCloseProtectionSuppressesCrossWorkspaceFocus() {
        var protection = NativeFocusRaceProtection()
        protection.recordWindowClose(workspaceName: "a", now: now)

        XCTAssertTrue(protection.shouldSuppressAfterClose(
            currentWorkspaceName: "a",
            nativeWorkspaceName: "b",
            now: now,
        ))
    }

    func testCloseProtectionOnlySuppressesFocusLeavingTheClosedWorkspace() {
        var protection = NativeFocusRaceProtection()
        protection.recordWindowClose(workspaceName: "a", now: now)

        XCTAssertFalse(protection.shouldSuppressAfterClose(
            currentWorkspaceName: "a",
            nativeWorkspaceName: "a",
            now: now,
        ))
        XCTAssertFalse(protection.shouldSuppressAfterClose(
            currentWorkspaceName: "b",
            nativeWorkspaceName: "c",
            now: now,
        ))
    }

    func testCloseProtectionExpires() {
        var protection = NativeFocusRaceProtection()
        protection.recordWindowClose(workspaceName: "a", now: now)

        XCTAssertFalse(protection.shouldSuppressAfterClose(
            currentWorkspaceName: "a",
            nativeWorkspaceName: "b",
            now: now.advanced(by: NativeFocusRaceProtection.closeProtectionDuration),
        ))
    }

    func testAppActivationDelaysCrossWorkspaceFocus() {
        var protection = NativeFocusRaceProtection()
        protection.recordAppActivation(appPid: 42, now: now)

        XCTAssertEqual(
            protection.appActivationDelay(
                appPid: 42,
                currentWorkspaceName: "a",
                nativeWorkspaceName: "b",
                now: now,
            ),
            NativeFocusRaceProtection.appActivationGraceDuration,
        )
        XCTAssertNil(protection.appActivationDelay(
            appPid: 42,
            currentWorkspaceName: "a",
            nativeWorkspaceName: "a",
            now: now,
        ))
        XCTAssertNil(protection.appActivationDelay(
            appPid: 7,
            currentWorkspaceName: "a",
            nativeWorkspaceName: "b",
            now: now,
        ))
    }

    func testSameWorkspaceFocusClearsActivationDelay() {
        var protection = NativeFocusRaceProtection()
        protection.recordAppActivation(appPid: 42, now: now)
        protection.clearAppActivation(appPid: 42)

        XCTAssertNil(protection.appActivationDelay(
            appPid: 42,
            currentWorkspaceName: "a",
            nativeWorkspaceName: "b",
            now: now,
        ))
    }

    func testWorkspaceSwitchSuppressesDelayedCrossWorkspaceFocus() {
        var protection = NativeFocusRaceProtection()
        protection.recordWorkspaceSwitch(workspaceName: "b", now: now)

        XCTAssertTrue(protection.shouldSuppressAfterWorkspaceSwitch(
            currentWorkspaceName: "b",
            nativeWorkspaceName: "a",
            now: now,
        ))
    }

    func testWorkspaceSwitchOnlyProtectsItsTarget() {
        var protection = NativeFocusRaceProtection()
        protection.recordWorkspaceSwitch(workspaceName: "b", now: now)

        XCTAssertFalse(protection.shouldSuppressAfterWorkspaceSwitch(
            currentWorkspaceName: "b",
            nativeWorkspaceName: "b",
            now: now,
        ))
        XCTAssertFalse(protection.shouldSuppressAfterWorkspaceSwitch(
            currentWorkspaceName: "c",
            nativeWorkspaceName: "a",
            now: now,
        ))
    }

    func testWorkspaceSwitchProtectionExpires() {
        var protection = NativeFocusRaceProtection()
        protection.recordWorkspaceSwitch(workspaceName: "b", now: now)

        XCTAssertFalse(protection.shouldSuppressAfterWorkspaceSwitch(
            currentWorkspaceName: "b",
            nativeWorkspaceName: "a",
            now: now.advanced(by: NativeFocusRaceProtection.workspaceSwitchProtectionDuration),
        ))
    }

    func testWorkspaceSwitchProtectionCanBeCancelledForMouseIntent() {
        var protection = NativeFocusRaceProtection()
        protection.recordWorkspaceSwitch(workspaceName: "b", now: now)
        protection.clearWorkspaceSwitch()

        XCTAssertFalse(protection.shouldSuppressAfterWorkspaceSwitch(
            currentWorkspaceName: "b",
            nativeWorkspaceName: "a",
            now: now,
        ))
    }

    func testFocusFallbackForVanishedWindow() {
        // The focused window is gone: macOS picked the replacement, not the user
        XCTAssertTrue(isNativeFocusFallbackForVanishedWindow(
            focusedWindowId: 1,
            nativeFocusedWindowId: 2,
            windowExists: { $0 != 1 },
        ))
        // The focused window is still there: e.g. the user clicked a notification of another app
        XCTAssertFalse(isNativeFocusFallbackForVanishedWindow(
            focusedWindowId: 1,
            nativeFocusedWindowId: 2,
            windowExists: { _ in true },
        ))
        XCTAssertFalse(isNativeFocusFallbackForVanishedWindow(
            focusedWindowId: 1,
            nativeFocusedWindowId: 1,
            windowExists: { _ in false },
        ))
    }

    func testEmptyWorkspaceHoldsNativeFocusUnlessUtilityPopupHasIt() {
        // The dead window's app is still frontmost (quitting, or left without windows)
        XCTAssertTrue(shouldHoldNativeFocusForEmptyWorkspace(frontmostAppPid: 10, isFrontmostAppRegular: true, deadWindowAppPid: 10))
        // macOS already activated a regular app (of another workspace)
        XCTAssertTrue(shouldHoldNativeFocusForEmptyWorkspace(frontmostAppPid: 11, isFrontmostAppRegular: true, deadWindowAppPid: 10))
        XCTAssertTrue(shouldHoldNativeFocusForEmptyWorkspace(frontmostAppPid: nil, isFrontmostAppRegular: false, deadWindowAppPid: 10))
        // Raycast, Spotlight, or AeroSpace itself
        XCTAssertFalse(shouldHoldNativeFocusForEmptyWorkspace(frontmostAppPid: 11, isFrontmostAppRegular: false, deadWindowAppPid: 10))
    }

    func testDeclinedNativeFocusHoldsUntilNativeFocusMoves() {
        let declined = DeclinedNativeFocus(windowId: 7, appPid: 70, workspaceName: "a")
        // macOS kept the declined window focused: a later refresh must not take it for user intent
        XCTAssertTrue(declined.stillHolds(nativeFocusedWindowId: 7, frontmostAppPid: 70, currentWorkspaceName: "a"))
        // AX couldn't tell the focused window, but the declined app is still frontmost
        XCTAssertTrue(declined.stillHolds(nativeFocusedWindowId: nil, frontmostAppPid: 70, currentWorkspaceName: "a"))

        // The native focus moved: AeroSpace took it, or the user focused another window or app
        XCTAssertFalse(declined.stillHolds(nativeFocusedWindowId: 8, frontmostAppPid: 70, currentWorkspaceName: "a"))
        XCTAssertFalse(declined.stillHolds(nativeFocusedWindowId: nil, frontmostAppPid: 71, currentWorkspaceName: "a"))
        XCTAssertFalse(declined.stillHolds(nativeFocusedWindowId: nil, frontmostAppPid: nil, currentWorkspaceName: "a"))
        // The user left the workspace
        XCTAssertFalse(declined.stillHolds(nativeFocusedWindowId: 7, frontmostAppPid: 70, currentWorkspaceName: "b"))
    }

    func testCloseProtectionCanEndEarly() {
        var protection = NativeFocusRaceProtection()
        protection.recordWindowClose(workspaceName: "a", now: now)
        protection.clearWindowClose()

        XCTAssertFalse(protection.shouldSuppressAfterClose(
            currentWorkspaceName: "a",
            nativeWorkspaceName: "b",
            now: now,
        ))
    }

    func testFocusSinkIsForcedOnlyWhenRefusedAndStillWanted() {
        func force(_ pid: pid_t?, regular: Bool = true, empty: Bool = true, workspace: String = "a") -> Bool {
            shouldForceFocusSink(
                frontmostAppPid: pid,
                isFrontmostAppRegular: regular,
                isFocusedWorkspaceEmpty: empty,
                focusedWorkspaceName: workspace,
                requestedWorkspaceName: "a",
            )
        }
        // macOS kept another app active
        XCTAssertTrue(force(myPid + 1))
        // The activation was honored
        XCTAssertFalse(force(myPid))
        XCTAssertFalse(force(nil))
        // A utility popup (Raycast, Spotlight) took the focus meanwhile
        XCTAssertFalse(force(myPid + 1, regular: false))
        // The focus moved on: a window got focused, or another workspace
        XCTAssertFalse(force(myPid + 1, empty: false))
        XCTAssertFalse(force(myPid + 1, workspace: "b"))
    }
}
