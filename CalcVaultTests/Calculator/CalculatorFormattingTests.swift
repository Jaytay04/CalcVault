import Foundation
import XCTest
@testable import CalcVault

final class CalculatorFormattingTests: XCTestCase {
    func testOrdinaryFormattingAvoidsBinaryFloatingPointArtifacts() {
        let formatter = CalculatorFormatter()
        XCTAssertEqual(formatter.format(Decimal(string: "0.3")!), "0.3")
        XCTAssertEqual(formatter.format(Decimal(string: "-0")!), "0")
    }

    func testLocaleSeparatorChangesPresentationAndInputCanonicalization() {
        let formatter = CalculatorFormatter(decimalSeparator: ",")
        XCTAssertEqual(formatter.format(Decimal(string: "12.5")!), "12,5")
        XCTAssertEqual(formatter.canonicalizeInput("12,5"), "12.5")
        XCTAssertNil(formatter.canonicalizeInput("12,5,2"))
    }

    func testLongResultsUseBoundedScientificPresentation() {
        let formatter = CalculatorFormatter(maximumDisplayCharacters: 8)
        let text = formatter.format(Decimal(string: "123456789012345")!)
        XCTAssertTrue(text.contains("e"))
    }

    func testNonfiniteScientificValuesAreRejectedFromDisplay() {
        XCTAssertEqual(CalculatorFormatter().formatScientific(.infinity), "Error")
    }
}
