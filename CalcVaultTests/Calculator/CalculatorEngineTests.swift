import Foundation
import XCTest
@testable import CalcVault

final class CalculatorEngineTests: XCTestCase {
    func testBasicPrecedenceAndCompletion() {
        var engine = CalculatorEngine()
        engine.inputDigit(2)
        engine.inputBinaryOperator(.add)
        engine.inputDigit(3)
        engine.inputBinaryOperator(.multiply)
        engine.inputDigit(4)
        engine.equals()

        XCTAssertEqual(engine.displayText, "14")
        XCTAssertEqual(engine.takeCompletion(), CalculatorCompletion(expression: "2+3×4", result: "14"))
    }

    func testRepeatedEqualsAndContinuedCalculation() {
        var engine = CalculatorEngine()
        engine.inputDigit(5)
        engine.inputBinaryOperator(.add)
        engine.inputDigit(2)
        engine.equals()
        XCTAssertEqual(engine.displayText, "7")
        engine.equals()
        XCTAssertEqual(engine.displayText, "9")
        engine.inputBinaryOperator(.multiply)
        engine.inputDigit(3)
        engine.equals()
        XCTAssertEqual(engine.displayText, "27")
    }

    func testOperatorReplacement() {
        var engine = CalculatorEngine()
        engine.inputDigit(8)
        engine.inputBinaryOperator(.add)
        engine.inputBinaryOperator(.subtract)
        engine.inputDigit(3)
        engine.equals()
        XCTAssertEqual(engine.displayText, "5")
    }

    func testLeadingZeroNegativeZeroDecimalAndDelete() {
        var engine = CalculatorEngine()
        engine.inputDigit(0)
        engine.inputDigit(0)
        engine.inputDigit(7)
        XCTAssertEqual(engine.displayText, "7")
        engine.allClear()
        engine.toggleSign()
        XCTAssertEqual(engine.displayText, "-0")
        engine.inputDecimalPoint()
        engine.inputDigit(5)
        XCTAssertEqual(engine.displayText, "-0.5")
        engine.deleteBackward()
        XCTAssertEqual(engine.displayText, "-0.")
    }

    func testClearThenAllClearSemantics() {
        var engine = CalculatorEngine()
        engine.inputDigit(8)
        engine.inputBinaryOperator(.add)
        engine.inputDigit(3)
        XCTAssertEqual(engine.clearButtonTitle, "C")

        engine.clear()
        XCTAssertEqual(engine.displayText, "0")
        XCTAssertEqual(engine.clearButtonTitle, "AC")

        engine.clear()
        XCTAssertEqual(engine.expressionText, "")
        XCTAssertEqual(engine.displayText, "0")
    }

    func testPercentUsesAdditiveAndMultiplicativeContexts() {
        var additive = CalculatorEngine()
        input(200, into: &additive)
        additive.inputBinaryOperator(.add)
        input(10, into: &additive)
        additive.percent()
        additive.equals()
        XCTAssertEqual(additive.displayText, "220")

        var multiplicative = CalculatorEngine()
        input(200, into: &multiplicative)
        multiplicative.inputBinaryOperator(.multiply)
        input(10, into: &multiplicative)
        multiplicative.percent()
        multiplicative.equals()
        XCTAssertEqual(multiplicative.displayText, "20")
    }

    func testParenthesesAndExpressionEntry() {
        var engine = CalculatorEngine()
        engine.openParenthesis()
        engine.inputDigit(2)
        engine.inputBinaryOperator(.add)
        engine.inputDigit(3)
        engine.closeParenthesis()
        engine.inputBinaryOperator(.multiply)
        engine.inputDigit(4)
        engine.equals()
        XCTAssertEqual(engine.displayText, "20")

        engine.evaluateExpression("3^(2+1)")
        XCTAssertEqual(engine.displayText, "27")
    }

    func testDivideByZeroAndMalformedExpressionAreVisible() {
        var engine = CalculatorEngine()
        engine.evaluateExpression("1÷0")
        XCTAssertEqual(engine.error, .divideByZero)
        XCTAssertEqual(engine.displayText, "Cannot divide by zero")
        engine.allClear()
        engine.evaluateExpression("(1+2")
        XCTAssertEqual(engine.error, .malformedExpression)
    }

    func testInputLengthIsBounded() {
        var engine = CalculatorEngine(maximumInputDigits: 3)
        engine.inputDigit(1)
        engine.inputDigit(2)
        engine.inputDigit(3)
        engine.inputDigit(4)
        XCTAssertEqual(engine.error, .inputTooLong)
    }

    func testScientificFunctionsAndDomains() {
        var engine = CalculatorEngine()
        engine.inputDigit(9)
        engine.applyScientific(.squareRoot)
        XCTAssertEqual(engine.displayText, "3")

        engine.allClear()
        engine.inputDigit(5)
        engine.applyScientific(.factorial)
        XCTAssertEqual(engine.displayText, "120")

        engine.allClear()
        engine.toggleSign()
        engine.inputDigit(1)
        engine.applyScientific(.squareRoot)
        XCTAssertEqual(engine.error, .domainError)
    }

    func testAngleUnitAndInverseTrigonometry() {
        var engine = CalculatorEngine()
        engine.inputDigit(3)
        engine.inputDigit(0)
        engine.applyScientific(.sine)
        XCTAssertEqual(Double(engine.displayText)!, 0.5, accuracy: 1e-12)

        engine.allClear()
        engine.inputDigit(1)
        engine.applyScientific(.inverseSine)
        XCTAssertEqual(engine.displayText, "90")
    }

    func testMemoryAndHistoryReuse() {
        var engine = CalculatorEngine()
        engine.inputDigit(4)
        engine.performMemory(.add)
        XCTAssertTrue(engine.hasMemory)
        engine.allClear()
        engine.performMemory(.recall)
        XCTAssertEqual(engine.displayText, "4")
        engine.performMemory(.clear)
        XCTAssertFalse(engine.hasMemory)

        engine.reuseHistoryResult("12.5")
        XCTAssertEqual(engine.displayText, "12.5")
    }

    private func input(_ value: Int, into engine: inout CalculatorEngine) {
        for character in String(value) {
            engine.inputDigit(character.wholeNumberValue!)
        }
    }
}
