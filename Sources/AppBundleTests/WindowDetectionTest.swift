@testable import AppBundle
import Common
import XCTest

final class WindowDetectionTest: XCTestCase {
    func testFirstRequestStartsSessionAndLaterRequestsAreCoalesced() {
        var scheduler = WindowDetectionScheduler()
        XCTAssertTrue(scheduler.requestDetection(pid: 42))
        XCTAssertTrue(scheduler.isDetecting)

        XCTAssertFalse(scheduler.requestDetection(pid: 42))
        XCTAssertFalse(scheduler.requestDetection(pid: 42))

        XCTAssertTrue(scheduler.finishPass(pid: 42)) // One more pass for both coalesced requests
        XCTAssertFalse(scheduler.finishPass(pid: 42))
        XCTAssertFalse(scheduler.isDetecting)
        XCTAssertTrue(scheduler.requestDetection(pid: 42))
    }

    func testSessionsOfDifferentAppsAreIndependent() {
        var scheduler = WindowDetectionScheduler()
        XCTAssertTrue(scheduler.requestDetection(pid: 1))
        XCTAssertTrue(scheduler.requestDetection(pid: 2))

        XCTAssertFalse(scheduler.finishPass(pid: 1))
        XCTAssertTrue(scheduler.isDetecting)
        XCTAssertFalse(scheduler.finishPass(pid: 2))
        XCTAssertFalse(scheduler.isDetecting)
    }

    func testFailedSessionEndsEvenIfAnotherPassWasRequested() {
        var scheduler = WindowDetectionScheduler()
        XCTAssertTrue(scheduler.requestDetection(pid: 42))
        XCTAssertFalse(scheduler.requestDetection(pid: 42))

        scheduler.endSession(pid: 42)

        XCTAssertFalse(scheduler.isDetecting)
        XCTAssertTrue(scheduler.requestDetection(pid: 42))
    }

    func testCompleteRefreshIsNotDeferredWhenIdle() {
        var scheduler = WindowDetectionScheduler()
        XCTAssertFalse(scheduler.deferCompleteRefreshIfDetecting(.init(event: .ax("a"), optimisticallyPreLayoutWorkspaces: false)))
        XCTAssertNil(scheduler.takeDeferredCompleteRefresh())
    }

    func testLatestCompleteRefreshIsDeferredUntilDetectionEnds() {
        var scheduler = WindowDetectionScheduler()
        XCTAssertTrue(scheduler.requestDetection(pid: 42))

        XCTAssertTrue(scheduler.deferCompleteRefreshIfDetecting(.init(event: .ax("a"), optimisticallyPreLayoutWorkspaces: false)))
        XCTAssertTrue(scheduler.deferCompleteRefreshIfDetecting(.init(event: .globalObserver("b"), optimisticallyPreLayoutWorkspaces: true)))

        XCTAssertFalse(scheduler.finishPass(pid: 42))
        let deferred = scheduler.takeDeferredCompleteRefresh()
        assertEquals(deferred?.event.description, "globalObserver(b)")
        assertEquals(deferred?.optimisticallyPreLayoutWorkspaces, true)
        XCTAssertNil(scheduler.takeDeferredCompleteRefresh())
    }

    func testWindowMissingFromSnapshotIsDead() {
        XCTAssertTrue(isDeadAfterWindowsSnapshot(windowId: 1, registrationIndex: 0, aliveWindowIds: [2], registrationsBeforeSnapshot: 5))
        XCTAssertFalse(isDeadAfterWindowsSnapshot(windowId: 2, registrationIndex: 0, aliveWindowIds: [2], registrationsBeforeSnapshot: 5))
    }

    func testWindowRegisteredDuringSnapshotIsNotDead() {
        XCTAssertFalse(isDeadAfterWindowsSnapshot(windowId: 1, registrationIndex: 5, aliveWindowIds: [], registrationsBeforeSnapshot: 5))
        XCTAssertFalse(isDeadAfterWindowsSnapshot(windowId: 1, registrationIndex: 6, aliveWindowIds: [], registrationsBeforeSnapshot: 5))
    }
}
