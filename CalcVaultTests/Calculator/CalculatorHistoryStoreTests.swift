import Foundation
import XCTest
@testable import CalcVault

final class CalculatorHistoryStoreTests: XCTestCase {
    func testAppendProducesStableIDsAndNewestFirstView() {
        let store = CalculatorHistoryStore(capacity: 3)
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        let first = store.append(expression: "2 + 3", result: "5", createdAt: firstDate)
        let second = store.append(expression: "5 × 4", result: "20", createdAt: secondDate)

        XCTAssertEqual(store.read(), [second, first])
        XCTAssertEqual(store.newestFirst, [second, first])
        XCTAssertEqual(store.inspect(id: first.id), first)
        XCTAssertEqual(store.inspect(id: second.id), second)
    }

    func testCapacityEvictsOldestRecordOnly() {
        let store = CalculatorHistoryStore(capacity: 2)

        let oldest = store.append(expression: "1 + 1", result: "2")
        let middle = store.append(expression: "2 + 2", result: "4")
        let newest = store.append(expression: "4 + 4", result: "8")

        XCTAssertEqual(store.read(), [newest, middle])
        XCTAssertNil(store.inspect(id: oldest.id))
        XCTAssertEqual(store.count, 2)
    }

    func testInspectAndReuseLookupAreReadOnlyAndReturnTheSameStableRecord() {
        let store = CalculatorHistoryStore()
        let entry = store.append(expression: "sqrt(9)", result: "3")

        XCTAssertEqual(store.lookupForReuse(id: entry.id), entry)
        XCTAssertEqual(store.read(), [entry])
        XCTAssertNil(store.lookupForReuse(id: UUID()))
    }

    func testDeleteRemovesOnlyRequestedRecord() {
        let store = CalculatorHistoryStore(capacity: 3)
        let first = store.append(expression: "3 - 1", result: "2")
        let second = store.append(expression: "6 ÷ 2", result: "3")
        let third = store.append(expression: "7 × 2", result: "14")

        XCTAssertTrue(store.delete(id: second.id))
        XCTAssertEqual(store.read(), [third, first])
        XCTAssertEqual(store.inspect(id: first.id)?.id, first.id)
        XCTAssertEqual(store.inspect(id: third.id)?.id, third.id)
        XCTAssertFalse(store.delete(id: second.id))
    }

    func testClearAllRemovesEveryRecordAndReuseCannotRecoverIt() {
        let store = CalculatorHistoryStore(capacity: 2)
        let first = store.append(expression: "8 + 1", result: "9")
        _ = store.append(expression: "9 + 1", result: "10")

        store.clearAll()

        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.read().isEmpty)
        XCTAssertNil(store.inspect(id: first.id))
        XCTAssertNil(store.lookupForReuse(id: first.id))
    }

    func testHistoryIsInMemoryOnlyAndStoresOrdinaryCalculationFields() {
        let firstStore = CalculatorHistoryStore()
        let entry = firstStore.append(expression: "0.1 + 0.2", result: "0.3")
        let secondStore = CalculatorHistoryStore()

        XCTAssertEqual(entry.expression, "0.1 + 0.2")
        XCTAssertEqual(entry.result, "0.3")
        XCTAssertTrue(secondStore.isEmpty)
    }
}
