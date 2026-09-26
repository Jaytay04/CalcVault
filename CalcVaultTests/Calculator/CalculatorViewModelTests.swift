import XCTest
@testable import CalcVault

@MainActor
final class CalculatorViewModelTests: XCTestCase {
    func testSuccessfulEqualsPublishesOrdinaryHistory() {
        let model = CalculatorViewModel()
        model.digit(4)
        model.binary(.add)
        model.digit(6)
        model.equals()

        XCTAssertEqual(model.engine.displayText, "10")
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.expression, "4+6")
        XCTAssertEqual(model.history.first?.result, "10")
    }

    func testErrorDoesNotPublishHistory() {
        let model = CalculatorViewModel()
        model.digit(1)
        model.binary(.divide)
        model.digit(0)
        model.equals()

        XCTAssertEqual(model.engine.error, .divideByZero)
        XCTAssertTrue(model.history.isEmpty)
    }

    func testReuseAndDeletionAreExplicit() throws {
        let store = CalculatorHistoryStore()
        let entry = store.append(expression: "2+3", result: "5")
        let model = CalculatorViewModel(historyStore: store)

        model.reuse(entry)
        XCTAssertEqual(model.engine.displayText, "5")
        XCTAssertEqual(model.history, [entry])

        model.deleteHistory(entry)
        XCTAssertTrue(model.history.isEmpty)
    }

    func testClearHistoryDoesNotChangeCurrentCalculation() {
        let store = CalculatorHistoryStore()
        _ = store.append(expression: "1+1", result: "2")
        let model = CalculatorViewModel(historyStore: store)
        model.digit(7)

        model.clearHistory()

        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(model.engine.displayText, "7")
    }

    func testMatchingSecretIsConsumedBeforeCalculationAndHistory() throws {
        var authenticationRequests = 0
        let model = CalculatorViewModel()
        try model.configureSecretEntry(sequence: "00123456") {
            authenticationRequests += 1
        }

        for digit in [0, 0, 1, 2, 3, 4, 5, 6] {
            model.digit(digit)
        }
        model.equals()

        XCTAssertEqual(authenticationRequests, 1)
        XCTAssertEqual(model.engine.displayText, "0")
        XCTAssertEqual(model.engine.expressionText, "")
        XCTAssertTrue(model.history.isEmpty)
        model.equals()
        XCTAssertEqual(authenticationRequests, 1)
    }

    func testSingleDigitEntryRequestsAuthenticationWithoutPublishingHistory() throws {
        var authenticationRequests = 0
        let model = CalculatorViewModel()
        try model.configureSecretEntry(sequence: "0") {
            authenticationRequests += 1
        }

        model.digit(0)
        model.equals()

        XCTAssertEqual(authenticationRequests, 1)
        XCTAssertEqual(model.engine.displayText, "0")
        XCTAssertTrue(model.history.isEmpty)
    }

    func testHistoryRecallCannotParticipateInSecretEntry() throws {
        var authenticationRequests = 0
        let store = CalculatorHistoryStore()
        let entry = store.append(expression: "123456+0", result: "00123456")
        let model = CalculatorViewModel(historyStore: store)
        try model.configureSecretEntry(sequence: "00123456") {
            authenticationRequests += 1
        }

        model.reuse(entry)
        model.equals()

        XCTAssertEqual(authenticationRequests, 0)
    }

    func testSecretEntryTimesOutAndRequiresExplicitFreshEntry() throws {
        var instant = Date(timeIntervalSince1970: 1_000)
        var authenticationRequests = 0
        let model = CalculatorViewModel(secretEntryTimeout: 5, now: { instant })
        try model.configureSecretEntry(sequence: "12345678") {
            authenticationRequests += 1
        }

        for digit in [1, 2, 3, 4] { model.digit(digit) }
        instant.addTimeInterval(6)
        for digit in [5, 6, 7, 8] { model.digit(digit) }
        model.equals()
        XCTAssertEqual(authenticationRequests, 0)

        model.allClear()
        for digit in [1, 2, 3, 4, 5, 6, 7, 8] { model.digit(digit) }
        model.equals()
        XCTAssertEqual(authenticationRequests, 1)
    }
}
