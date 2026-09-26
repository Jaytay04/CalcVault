import Foundation

public enum CalculatorAngleUnit: String, CaseIterable, Hashable, Sendable {
    case degrees = "Deg"
    case radians = "Rad"
}

public enum CalculatorScientificFunction: String, CaseIterable, Sendable {
    case square
    case cube
    case squareRoot
    case cubeRoot
    case reciprocal
    case factorial
    case naturalLog
    case commonLog
    case exponential
    case tenPower
    case sine
    case cosine
    case tangent
    case inverseSine
    case inverseCosine
    case inverseTangent
}

public enum CalculatorConstant: Sendable {
    case pi
    case e
}

public enum CalculatorMemoryOperation: Sendable {
    case clear
    case recall
    case add
    case subtract
}

public struct CalculatorCompletion: Equatable, Sendable {
    public let expression: String
    public let result: String
}

public struct CalculatorEngine: Sendable {
    public private(set) var displayText = "0"
    public private(set) var expressionText = ""
    public private(set) var error: CalculatorError?
    public private(set) var angleUnit: CalculatorAngleUnit = .degrees
    public private(set) var hasMemory = false

    public var clearButtonTitle: String {
        enteringNumber ? "C" : "AC"
    }

    private let formatter: CalculatorFormatter
    private let parser: ExpressionParser
    private let maximumInputDigits: Int
    private var rawInput = "0"
    private var prefix = ""
    private var enteringNumber = false
    private var justEvaluated = false
    private var openParenthesisCount = 0
    private var repeatedOperation: RepeatedOperation?
    private var memory: Decimal = 0
    private var completion: CalculatorCompletion?

    public init(maximumInputDigits: Int = 16) {
        self.maximumInputDigits = maximumInputDigits
        self.formatter = CalculatorFormatter(maximumDisplayCharacters: maximumInputDigits)
        self.parser = ExpressionParser()
    }

    public mutating func inputDigit(_ digit: Int) {
        guard (0...9).contains(digit) else { return }
        prepareForNumericInput()
        guard digitCount < maximumInputDigits else {
            setError(.inputTooLong)
            return
        }
        if rawInput == "0" {
            rawInput = String(digit)
        } else if rawInput == "-0" {
            rawInput = digit == 0 ? "-0" : "-\(digit)"
        } else {
            rawInput.append(String(digit))
        }
        enteringNumber = true
        refreshDisplayFromInput()
    }

    public mutating func inputDecimalPoint() {
        prepareForNumericInput()
        guard !rawInput.contains(".") else { return }
        rawInput.append(".")
        enteringNumber = true
        refreshDisplayFromInput()
    }

    public mutating func toggleSign() {
        guard recoverFromErrorIfNeeded() else { return }
        if rawInput.hasPrefix("-") {
            rawInput.removeFirst()
        } else {
            rawInput = "-" + rawInput
        }
        enteringNumber = true
        justEvaluated = false
        refreshDisplayFromInput()
    }

    public mutating func deleteBackward() {
        guard error == nil, enteringNumber else { return }
        if rawInput.count <= 1 || (rawInput.hasPrefix("-") && rawInput.count == 2) {
            rawInput = "0"
        } else {
            rawInput.removeLast()
        }
        refreshDisplayFromInput()
    }

    public mutating func clearEntry() {
        if error != nil {
            allClear()
            return
        }
        rawInput = "0"
        displayText = "0"
        enteringNumber = false
        justEvaluated = false
        completion = nil
    }

    public mutating func clear() {
        if enteringNumber {
            clearEntry()
        } else {
            allClear()
        }
    }

    public mutating func allClear() {
        displayText = "0"
        expressionText = ""
        error = nil
        rawInput = "0"
        prefix = ""
        enteringNumber = false
        justEvaluated = false
        openParenthesisCount = 0
        repeatedOperation = nil
        completion = nil
    }

    public mutating func inputBinaryOperator(_ operation: CalculatorBinaryOperator) {
        guard recoverFromErrorIfNeeded() else { return }
        if justEvaluated {
            prefix = canonicalCurrentValue()
            justEvaluated = false
            repeatedOperation = nil
        } else if enteringNumber {
            prefix += canonicalCurrentValue()
        } else if prefix.isEmpty {
            prefix = canonicalCurrentValue()
        }

        if let last = prefix.last, Self.isOperator(last) {
            prefix.removeLast()
        }
        prefix += operation.rawValue
        expressionText = prefix
        enteringNumber = false
        rawInput = "0"
        completion = nil
    }

    public mutating func openParenthesis() {
        guard recoverFromErrorIfNeeded() else { return }
        if justEvaluated {
            resetCalculationKeepingMemory()
        }
        if enteringNumber {
            prefix += canonicalCurrentValue() + CalculatorBinaryOperator.multiply.rawValue
        } else if let last = prefix.last, last == ")" {
            prefix += CalculatorBinaryOperator.multiply.rawValue
        }
        prefix += "("
        openParenthesisCount += 1
        expressionText = prefix
        rawInput = "0"
        enteringNumber = false
    }

    public mutating func closeParenthesis() {
        guard error == nil, openParenthesisCount > 0, enteringNumber else {
            setError(.malformedExpression)
            return
        }
        prefix += canonicalCurrentValue() + ")"
        openParenthesisCount -= 1
        expressionText = prefix
        enteringNumber = false
    }

    public mutating func percent() {
        guard let current = currentDecimal() else {
            setError(.malformedExpression)
            return
        }
        do {
            var result = current / 100
            if let operation = trailingOperation(), operation == .add || operation == .subtract {
                let lhsText = String(prefix.dropLast())
                if !lhsText.isEmpty {
                    result = try parser.evaluate(lhsText) * current / 100
                }
            }
            setCurrent(result)
            enteringNumber = true
            justEvaluated = false
        } catch let calculatorError as CalculatorError {
            setError(calculatorError)
        } catch {
            setError(.malformedExpression)
        }
    }

    public mutating func equals() {
        guard error == nil else { return }
        if justEvaluated, let repeatedOperation, let lhs = currentDecimal() {
            do {
                let result = try parser.apply(repeatedOperation.operation, lhs: lhs, rhs: repeatedOperation.rhs)
                let expression = "\(formatter.format(lhs)) \(repeatedOperation.operation.rawValue) \(formatter.format(repeatedOperation.rhs))"
                finish(result: result, expression: expression, keepRepeatedOperation: true)
            } catch let calculatorError as CalculatorError {
                setError(calculatorError)
            } catch {
                setError(.malformedExpression)
            }
            return
        }

        guard openParenthesisCount == 0 else {
            setError(.malformedExpression)
            return
        }
        var source = prefix
        if enteringNumber || source.isEmpty {
            source += canonicalCurrentValue()
        }
        guard !source.isEmpty, source.last.map({ !Self.isOperator($0) }) == true else {
            setError(.malformedExpression)
            return
        }

        let newRepeatedOperation = repeatedOperationForCurrentExpression()
        do {
            let result = try parser.evaluate(source)
            repeatedOperation = newRepeatedOperation
            finish(result: result, expression: source, keepRepeatedOperation: true)
        } catch let calculatorError as CalculatorError {
            setError(calculatorError)
        } catch {
            setError(.malformedExpression)
        }
    }

    public mutating func evaluateExpression(_ source: String) {
        do {
            let result = try parser.evaluate(source)
            repeatedOperation = nil
            finish(result: result, expression: source, keepRepeatedOperation: false)
        } catch let calculatorError as CalculatorError {
            setError(calculatorError)
        } catch {
            setError(.malformedExpression)
        }
    }

    public mutating func applyScientific(_ function: CalculatorScientificFunction) {
        guard error == nil, let decimal = currentDecimal() else {
            setError(.malformedExpression)
            return
        }
        do {
            let result = try scientificResult(function, input: decimal)
            setCurrent(result)
            prefix = ""
            expressionText = function.rawValue
            enteringNumber = false
            justEvaluated = true
            repeatedOperation = nil
            completion = CalculatorCompletion(expression: function.rawValue, result: displayText)
        } catch let calculatorError as CalculatorError {
            setError(calculatorError)
        } catch {
            setError(.domainError)
        }
    }

    public mutating func inputConstant(_ constant: CalculatorConstant) {
        let value: Double
        switch constant {
        case .pi: value = Double.pi
        case .e: value = Foundation.exp(1)
        }
        guard let decimal = Self.decimal(value) else {
            setError(.overflow)
            return
        }
        setCurrent(decimal)
        enteringNumber = true
        justEvaluated = false
    }

    public mutating func setAngleUnit(_ unit: CalculatorAngleUnit) {
        angleUnit = unit
    }

    public mutating func performMemory(_ operation: CalculatorMemoryOperation) {
        switch operation {
        case .clear:
            memory = 0
            hasMemory = false
        case .recall:
            setCurrent(memory)
            enteringNumber = true
            justEvaluated = false
        case .add:
            guard let value = currentDecimal() else { return }
            memory += value
            hasMemory = true
        case .subtract:
            guard let value = currentDecimal() else { return }
            memory -= value
            hasMemory = true
        }
    }

    public mutating func takeCompletion() -> CalculatorCompletion? {
        defer { completion = nil }
        return completion
    }

    public mutating func reuseHistoryResult(_ result: String) {
        guard let value = Decimal(string: result, locale: Self.posixLocale) else {
            setError(.malformedExpression)
            return
        }
        resetCalculationKeepingMemory()
        setCurrent(value)
        enteringNumber = true
    }

    private mutating func prepareForNumericInput() {
        if error != nil || justEvaluated {
            resetCalculationKeepingMemory()
        }
        if !enteringNumber {
            rawInput = "0"
        }
    }

    @discardableResult
    private mutating func recoverFromErrorIfNeeded() -> Bool {
        if error != nil {
            allClear()
        }
        return true
    }

    private mutating func resetCalculationKeepingMemory() {
        displayText = "0"
        expressionText = ""
        error = nil
        rawInput = "0"
        prefix = ""
        enteringNumber = false
        justEvaluated = false
        openParenthesisCount = 0
        repeatedOperation = nil
        completion = nil
    }

    private mutating func finish(result: Decimal, expression: String, keepRepeatedOperation: Bool) {
        setCurrent(result)
        expressionText = expression
        prefix = ""
        enteringNumber = false
        justEvaluated = true
        openParenthesisCount = 0
        if !keepRepeatedOperation { repeatedOperation = nil }
        completion = CalculatorCompletion(expression: expression, result: displayText)
    }

    private mutating func setCurrent(_ value: Decimal) {
        rawInput = NSDecimalNumber(decimal: value).stringValue
        displayText = formatter.format(value)
    }

    private mutating func setError(_ value: CalculatorError) {
        error = value
        displayText = value.errorDescription ?? "Error"
        expressionText = ""
        prefix = ""
        enteringNumber = false
        justEvaluated = false
        openParenthesisCount = 0
        repeatedOperation = nil
        completion = nil
    }

    private mutating func refreshDisplayFromInput() {
        displayText = rawInput
    }

    private func canonicalCurrentValue() -> String {
        rawInput.hasSuffix(".") ? String(rawInput.dropLast()) : rawInput
    }

    private func currentDecimal() -> Decimal? {
        Decimal(string: canonicalCurrentValue(), locale: Self.posixLocale)
    }

    private var digitCount: Int {
        rawInput.filter(\.isNumber).count
    }

    private func trailingOperation() -> CalculatorBinaryOperator? {
        guard let last = prefix.last else { return nil }
        return CalculatorBinaryOperator.allCases.first { $0.rawValue.first == last }
    }

    private func repeatedOperationForCurrentExpression() -> RepeatedOperation? {
        guard enteringNumber, let rhs = currentDecimal(), let operation = trailingOperation() else {
            return nil
        }
        return RepeatedOperation(operation: operation, rhs: rhs)
    }

    private func scientificResult(
        _ function: CalculatorScientificFunction,
        input: Decimal
    ) throws -> Decimal {
        if function == .factorial {
            let number = NSDecimalNumber(decimal: input)
            let integer = number.intValue
            guard input >= 0, Decimal(integer) == input, integer <= 69 else {
                throw CalculatorError.domainError
            }
            var result: Decimal = 1
            if integer > 1 {
                for value in 2...integer { result *= Decimal(value) }
            }
            return result
        }

        let value = NSDecimalNumber(decimal: input).doubleValue
        let angle = angleUnit == .degrees ? value * .pi / 180 : value
        let output: Double
        switch function {
        case .square: output = value * value
        case .cube: output = value * value * value
        case .squareRoot:
            guard value >= 0 else { throw CalculatorError.domainError }
            output = Foundation.sqrt(value)
        case .cubeRoot: output = Foundation.cbrt(value)
        case .reciprocal:
            guard value != 0 else { throw CalculatorError.divideByZero }
            output = 1 / value
        case .naturalLog:
            guard value > 0 else { throw CalculatorError.domainError }
            output = Foundation.log(value)
        case .commonLog:
            guard value > 0 else { throw CalculatorError.domainError }
            output = Foundation.log10(value)
        case .exponential: output = Foundation.exp(value)
        case .tenPower: output = Foundation.pow(10, value)
        case .sine: output = Foundation.sin(angle)
        case .cosine: output = Foundation.cos(angle)
        case .tangent:
            guard abs(Foundation.cos(angle)) > 1e-14 else { throw CalculatorError.domainError }
            output = Foundation.tan(angle)
        case .inverseSine:
            guard (-1...1).contains(value) else { throw CalculatorError.domainError }
            output = inverseAngle(Foundation.asin(value))
        case .inverseCosine:
            guard (-1...1).contains(value) else { throw CalculatorError.domainError }
            output = inverseAngle(Foundation.acos(value))
        case .inverseTangent: output = inverseAngle(Foundation.atan(value))
        case .factorial: preconditionFailure("Handled above")
        }
        guard output.isFinite, let decimal = Self.decimal(output) else {
            throw CalculatorError.overflow
        }
        return decimal
    }

    private func inverseAngle(_ radians: Double) -> Double {
        angleUnit == .degrees ? radians * 180 / .pi : radians
    }

    private static func decimal(_ value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        return Decimal(string: String(format: "%.15g", locale: posixLocale, value), locale: posixLocale)
    }

    private static func isOperator(_ character: Character) -> Bool {
        CalculatorBinaryOperator.allCases.contains { $0.rawValue.first == character }
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private struct RepeatedOperation: Sendable {
        let operation: CalculatorBinaryOperator
        let rhs: Decimal
    }
}
