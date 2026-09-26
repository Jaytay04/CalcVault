import Foundation
import XCTest
@testable import CalcVault

final class ExpressionParserTests: XCTestCase {
    private let parser = ExpressionParser()

    func testDecimalArithmeticIsExact() throws {
        XCTAssertEqual(try parser.evaluate("0.1+0.2"), Decimal(string: "0.3"))
        XCTAssertEqual(try parser.evaluate("12.5-2.25"), Decimal(string: "10.25"))
    }

    func testPrecedenceParenthesesAndRightAssociativePower() throws {
        XCTAssertEqual(try parser.evaluate("2+3×4"), 14)
        XCTAssertEqual(try parser.evaluate("(2+3)×4"), 20)
        XCTAssertEqual(try parser.evaluate("2^3^2"), 512)
    }

    func testAlternateOperatorGlyphsAndUnarySign() throws {
        XCTAssertEqual(try parser.evaluate("-8 / 2 + 7 * 3"), 17)
        XCTAssertEqual(try parser.evaluate("4−9"), -5)
        XCTAssertEqual(try parser.evaluate("9÷3"), 3)
    }

    func testLocaleDecimalSeparatorIsExplicit() throws {
        let commaParser = ExpressionParser(decimalSeparator: ",")
        XCTAssertEqual(try commaParser.evaluate("1,5+2,25"), Decimal(string: "3.75"))
        XCTAssertThrowsError(try commaParser.evaluate("1.5+2"))
    }

    func testDivisionByZeroAndMalformedInputAreTyped() {
        XCTAssertThrowsError(try parser.evaluate("1÷0")) { error in
            XCTAssertEqual(error as? CalculatorError, .divideByZero)
        }
        for expression in ["", "2+", "(2+3", "2..3", "hello"] {
            XCTAssertThrowsError(try parser.evaluate(expression), expression)
        }
    }

    func testSourceAndExponentBoundsFailClosed() {
        XCTAssertThrowsError(try ExpressionParser(maximumSourceLength: 3).evaluate("12+3")) { error in
            XCTAssertEqual(error as? CalculatorError, .inputTooLong)
        }
        XCTAssertThrowsError(try parser.evaluate("2^513")) { error in
            XCTAssertEqual(error as? CalculatorError, .overflow)
        }
    }
}
