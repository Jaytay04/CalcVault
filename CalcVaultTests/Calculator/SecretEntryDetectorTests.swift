import Foundation
import XCTest
@testable import CalcVault

final class SecretEntryDetectorTests: XCTestCase {
    private let sequence = "00123456"

    func testConfigurationRequiresOneToTwelveASCIIDigitsOnly() throws {
        XCTAssertThrowsError(try SecretEntryConfiguration(sequence: ""))
        XCTAssertThrowsError(try SecretEntryConfiguration(sequence: "1234567890123"))
        XCTAssertThrowsError(try SecretEntryConfiguration(sequence: "1234abcd"))
        XCTAssertThrowsError(try SecretEntryConfiguration(sequence: "１２３４５６７８"))

        let configuration = try SecretEntryConfiguration(sequence: sequence)
        XCTAssertEqual(configuration.digitCount, 8)
        XCTAssertEqual(configuration.delimiter, .equals)
        XCTAssertEqual(try SecretEntryConfiguration(sequence: "0").digitCount, 1)
    }

    func testSingleDigitSequenceRequiresFreshManualEntryAndEquals() throws {
        var detector = SecretEntryDetector(configuration: try SecretEntryConfiguration(sequence: "0"))
        XCTAssertEqual(detector.receive(.digit(48, source: .manualKeypad)), .tracking)
        XCTAssertEqual(detector.receive(.delimiter(.equals)), .unlockRequested)
        XCTAssertEqual(detector.receive(.digit(48, source: .manualKeypad)), .ignored)
        _ = detector.receive(.freshSession)
        XCTAssertEqual(detector.receive(.numericEntry("0", source: .historyRecall)), .reset)
        XCTAssertEqual(detector.receive(.delimiter(.equals)), .ignored)
    }

    func testCorrectMatchPreservesLeadingZerosAndRequestsUnlockOnce() throws {
        var detector = try makeDetector()

        XCTAssertEqual(detector.receive(.allClear), .reset)
        for digit in sequence.utf8 {
            XCTAssertEqual(detector.receive(.digit(digit, source: .manualKeypad)), .tracking)
        }
        XCTAssertEqual(detector.candidateLength, sequence.count)
        XCTAssertEqual(detector.receive(.delimiter(.equals)), .unlockRequested)
        XCTAssertEqual(detector.candidateLength, 0)
        XCTAssertFalse(detector.isCollecting)
        XCTAssertEqual(detector.receive(.delimiter(.equals)), .ignored)
    }

    func testARecreatedDetectorStartsAsAFreshCalculatorSession() throws {
        var detector = try makeDetector()
        for digit in sequence.utf8 {
            _ = detector.receive(.digit(digit, source: .manualKeypad))
        }
        XCTAssertEqual(detector.receive(.delimiter(.equals)), .unlockRequested)
    }

    func testNonmatchDoesNotRequestUnlockOrRollAcrossExpressions() throws {
        var detector = try makeDetector()
        _ = detector.receive(.freshSession)
        for digit in "00123457".utf8 {
            XCTAssertEqual(detector.receive(.digit(digit, source: .manualKeypad)), .tracking)
        }
        XCTAssertEqual(detector.receive(.delimiter(.equals)), .reset)

        // The suffix of this unrelated expression must not become a trigger.
        for digit in "00123456".utf8 {
            XCTAssertEqual(detector.receive(.digit(digit, source: .manualKeypad)), .ignored)
        }
        XCTAssertEqual(detector.receive(.delimiter(.equals)), .ignored)

        _ = detector.receive(.allClear)
        for digit in sequence.utf8 {
            _ = detector.receive(.digit(digit, source: .manualKeypad))
        }
        XCTAssertEqual(detector.receive(.delimiter(.equals)), .unlockRequested)
    }

    func testOnlyExplicitManualDigitSourcesParticipate() throws {
        var detector = try makeDetector()
        let excludedSources: [SecretEntryInputSource] = [
            .pastedText, .historyRecall, .calculationResult, .importedExpression
        ]

        for source in excludedSources {
            _ = detector.receive(.allClear)
            XCTAssertEqual(
                detector.receive(.numericEntry(sequence, source: source)),
                .reset
            )
            XCTAssertEqual(detector.receive(.delimiter(.equals)), .ignored)
        }

        _ = detector.receive(.allClear)
        for digit in sequence.utf8 {
            _ = detector.receive(.digit(digit, source: .manualPhysicalKeyboard))
        }
        XCTAssertEqual(detector.receive(.delimiter(.equals)), .unlockRequested)
    }

    func testInterruptedSequenceResetsOnOperatorsDecimalSignAndCompletedCalculation() throws {
        let resetEvents: [SecretEntryEvent] = [
            .unrelatedOperator, .decimal, .signTransformation, .completedCalculation
        ]

        for event in resetEvents {
            var detector = try makeDetector()
            _ = detector.receive(.allClear)
            for digit in "0012".utf8 {
                _ = detector.receive(.digit(digit, source: .manualKeypad))
            }
            XCTAssertEqual(detector.receive(event), .reset)
            for digit in sequence.utf8 {
                XCTAssertEqual(detector.receive(.digit(digit, source: .manualKeypad)), .ignored)
            }
            XCTAssertEqual(detector.receive(.delimiter(.equals)), .ignored)
        }
    }

    func testTimeoutBackgroundAndLockRequireFreshEntry() throws {
        let resetEvents: [SecretEntryEvent] = [.timeout, .backgrounded, .locked]
        for event in resetEvents {
            var detector = try makeDetector()
            _ = detector.receive(.freshSession)
            for digit in "0012".utf8 {
                _ = detector.receive(.digit(digit, source: .manualKeypad))
            }
            XCTAssertEqual(detector.receive(event), .reset)
            XCTAssertEqual(detector.receive(.digit(48, source: .manualKeypad)), .ignored)
            XCTAssertEqual(detector.receive(.delimiter(.equals)), .ignored)

            _ = detector.receive(.freshSession)
            for digit in sequence.utf8 {
                _ = detector.receive(.digit(digit, source: .manualKeypad))
            }
            XCTAssertEqual(detector.receive(.delimiter(.equals)), .unlockRequested)
        }
    }

    func testExcessDigitsAreBoundedAndCannotRollIntoASecondMatch() throws {
        var detector = try makeDetector()
        _ = detector.receive(.allClear)
        for digit in sequence.utf8 {
            XCTAssertEqual(detector.receive(.digit(digit, source: .manualKeypad)), .tracking)
        }
        XCTAssertEqual(detector.receive(.digit(57, source: .manualKeypad)), .reset)
        XCTAssertEqual(detector.candidateLength, 0)
        XCTAssertEqual(detector.receive(.delimiter(.equals)), .ignored)
    }

    func testDelimiterAndDuplicateDelimiterNeverPublishAHistoryEntry() throws {
        var detector = try makeDetector()
        _ = detector.receive(.freshSession)
        for digit in sequence.utf8 {
            _ = detector.receive(.digit(digit, source: .manualKeypad))
        }

        let result = detector.receive(.delimiter(.equals))
        XCTAssertEqual(result, .unlockRequested)
        XCTAssertEqual(detector.receive(.delimiter(.equals)), .ignored)
        XCTAssertEqual(detector.receive(.completedCalculation), .reset)
    }

    func testConstantTimeComparisonIsExactForEqualAndUnequalBytes() {
        XCTAssertTrue(SecretEntryDetector.constantTimeEquals(Array("00123456".utf8), Array("00123456".utf8)))
        XCTAssertFalse(SecretEntryDetector.constantTimeEquals(Array("00123456".utf8), Array("00123457".utf8)))
        XCTAssertFalse(SecretEntryDetector.constantTimeEquals(Array("00123456".utf8), Array("0012345".utf8)))
        XCTAssertFalse(SecretEntryDetector.constantTimeEquals(Array("00123456".utf8), Array("001234567".utf8)))
    }

    private func makeDetector() throws -> SecretEntryDetector {
        SecretEntryDetector(configuration: try SecretEntryConfiguration(sequence: sequence))
    }
}
