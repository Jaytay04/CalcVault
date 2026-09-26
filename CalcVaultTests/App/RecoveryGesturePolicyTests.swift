import XCTest
@testable import CalcVault

final class RecoveryGesturePolicyTests: XCTestCase {
    func testRecoveryGestureRequiresFifteenTaps() {
        XCTAssertEqual(RecoveryGesturePolicy.requiredTapCount, 15)
    }

    func testRecoveryGestureTriggersOnExactlyFifteenTaps() {
        var accumulator = RecoveryTapAccumulator()

        for _ in 0 ..< 14 {
            XCTAssertFalse(accumulator.registerTap())
        }

        XCTAssertTrue(accumulator.registerTap())
        XCTAssertEqual(accumulator.tapCount, 0)
    }

    func testRecoveryGestureDoesNotExpireBeforeFifteenTaps() {
        var accumulator = RecoveryTapAccumulator()

        for _ in 0 ..< 14 {
            XCTAssertFalse(accumulator.registerTap())
        }

        XCTAssertEqual(accumulator.tapCount, 14)
    }

    func testRecoveryGestureCanBeResetExplicitly() {
        var accumulator = RecoveryTapAccumulator()

        for _ in 0 ..< 14 {
            XCTAssertFalse(accumulator.registerTap())
        }

        accumulator.reset()
        XCTAssertFalse(accumulator.registerTap())
        XCTAssertEqual(accumulator.tapCount, 1)
    }

    func testRecoveryGestureStartsFreshAfterTrigger() {
        var accumulator = RecoveryTapAccumulator()

        for _ in 0 ..< RecoveryGesturePolicy.requiredTapCount {
            _ = accumulator.registerTap()
        }

        XCTAssertFalse(accumulator.registerTap())
        XCTAssertEqual(accumulator.tapCount, 1)
    }
}
