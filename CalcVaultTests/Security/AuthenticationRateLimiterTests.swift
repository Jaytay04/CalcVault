import Foundation
import XCTest
@testable import CalcVault

final class AuthenticationRateLimiterTests: XCTestCase {
    func testFailuresArePersistedAndDelayBeginsOnThirdFailure() {
        let store = MemoryRetryStore()
        var now = Date(timeIntervalSince1970: 10_000)
        let limiter = AuthenticationRateLimiter(store: store, now: { now })

        XCTAssertEqual(limiter.recordFailure(), 0)
        XCTAssertEqual(limiter.recordFailure(), 0)
        XCTAssertEqual(limiter.recordFailure(), 1)
        XCTAssertEqual(limiter.retryAfter(), 1)

        now.addTimeInterval(1)
        XCTAssertNil(limiter.retryAfter())
        XCTAssertEqual(store.state.failureCount, 3)
    }

    func testSuccessClearsPersistedFailureState() {
        let store = MemoryRetryStore()
        let limiter = AuthenticationRateLimiter(store: store)
        _ = limiter.recordFailure()
        _ = limiter.recordFailure()
        _ = limiter.recordFailure()

        limiter.recordSuccess()

        XCTAssertEqual(store.state, AuthenticationRetryState())
        XCTAssertNil(limiter.retryAfter())
    }

    func testDelayIsBoundedAndDoesNotWipeData() {
        let store = MemoryRetryStore()
        let limiter = AuthenticationRateLimiter(store: store)
        var delay: TimeInterval = 0
        for _ in 0..<32 { delay = limiter.recordFailure() }

        XCTAssertEqual(delay, 300)
        XCTAssertEqual(store.state.failureCount, 32)
    }
}

private final class MemoryRetryStore: AuthenticationRetryPersisting {
    var state = AuthenticationRetryState()

    func load() -> AuthenticationRetryState { state }
    func save(_ state: AuthenticationRetryState) { self.state = state }
}
