import XCTest
@testable import AppBundle

final class AxAppCircuitBreakerTest: XCTestCase {
    func testCircuitBreakerIsScopedToPidAndExpires() {
        var state = AxAppCircuitBreakerState()
        let now = ContinuousClock().now

        state.recordTimeout(for: 42, now: now)

        XCTAssertTrue(state.shouldSkipRequests(for: 42, now: now))
        XCTAssertFalse(state.shouldSkipRequests(for: 24, now: now))
        XCTAssertFalse(state.shouldSkipRequests(for: 42, now: now.advanced(by: AxAppCircuitBreakerState.cooldowns[0])))
    }

    func testRepeatedTimeoutsExtendCooldown() {
        var state = AxAppCircuitBreakerState()
        var now = ContinuousClock().now
        for cooldown in AxAppCircuitBreakerState.cooldowns + [.seconds(1)] {
            state.recordTimeout(for: 42, now: now)
            XCTAssertTrue(state.shouldSkipRequests(for: 42, now: now.advanced(by: cooldown - .milliseconds(1))))
            now = now.advanced(by: cooldown)
            XCTAssertFalse(state.shouldSkipRequests(for: 42, now: now))
        }
    }

    func testTimeoutStreakResets() {
        var state = AxAppCircuitBreakerState()
        let now = ContinuousClock().now
        state.recordTimeout(for: 42, now: now)
        state.recordTimeout(for: 42, now: now.advanced(by: .milliseconds(100)))
        let later = now.advanced(by: .milliseconds(100) + AxAppCircuitBreakerState.streakWindow)

        state.recordTimeout(for: 42, now: later)

        XCTAssertFalse(state.shouldSkipRequests(for: 42, now: later.advanced(by: AxAppCircuitBreakerState.cooldowns[0])))
    }

    func testRegistrationTimeoutDoesNotOpenCircuit() {
        var state = AxAppCircuitBreakerState()
        let now = ContinuousClock().now

        state.recordTimeout(for: 42, now: now, phase: .appRegistration)

        XCTAssertFalse(state.shouldSkipRequests(for: 42, now: now))
    }

    func testEstablishedAppTimeoutStillOpensCircuit() {
        var state = AxAppCircuitBreakerState()
        let now = ContinuousClock().now

        state.recordTimeout(for: 42, now: now, phase: .establishedApp)

        XCTAssertTrue(state.shouldSkipRequests(for: 42, now: now))
    }

    func testRemainingCooldown() {
        var state = AxAppCircuitBreakerState()
        let now = ContinuousClock().now
        XCTAssertNil(state.remainingCooldown(for: 42, now: now))

        state.recordTimeout(for: 42, now: now)

        XCTAssertEqual(state.remainingCooldown(for: 42, now: now), AxAppCircuitBreakerState.cooldowns[0])
        XCTAssertNil(state.remainingCooldown(for: 43, now: now))
        XCTAssertNil(state.remainingCooldown(for: 42, now: now.advanced(by: AxAppCircuitBreakerState.cooldowns[0])))
    }

    func testLayoutRetryBudgetIsBoundedAndRecovers() {
        var budget = AxCooldownLayoutRetryBudget()
        let now = ContinuousClock().now
        for i in 0 ..< AxCooldownLayoutRetryBudget.maxConsecutiveRetries {
            XCTAssertTrue(budget.takeRetry(now: now.advanced(by: .seconds(i))))
        }
        let last = now.advanced(by: .seconds(AxCooldownLayoutRetryBudget.maxConsecutiveRetries - 1))
        XCTAssertFalse(budget.takeRetry(now: last.advanced(by: .seconds(1))))

        XCTAssertTrue(budget.takeRetry(now: last.advanced(by: AxCooldownLayoutRetryBudget.resetAfter + .milliseconds(1))))
    }
}
