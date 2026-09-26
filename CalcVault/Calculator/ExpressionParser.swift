import Foundation

public enum CalculatorError: Error, Equatable, LocalizedError, Sendable {
    case malformedExpression
    case divideByZero
    case domainError
    case overflow
    case inputTooLong

    public var errorDescription: String? {
        switch self {
        case .malformedExpression:
            return "Malformed expression"
        case .divideByZero:
            return "Cannot divide by zero"
        case .domainError:
            return "Domain error"
        case .overflow:
            return "Result is too large"
        case .inputTooLong:
            return "Maximum input length reached"
        }
    }
}

public enum CalculatorBinaryOperator: String, CaseIterable, Equatable, Sendable {
    case add = "+"
    case subtract = "−"
    case multiply = "×"
    case divide = "÷"
    case power = "^"

    public var precedence: Int {
        switch self {
        case .add, .subtract: return 1
        case .multiply, .divide: return 2
        case .power: return 3
        }
    }
}

/// Deterministic arithmetic parser used independently of SwiftUI and the vault.
/// Ordinary arithmetic is Decimal-backed; non-integral powers use Double only
/// after explicit domain and finite-result checks.
public struct ExpressionParser: Sendable {
    private let decimalSeparator: Character
    private let maximumSourceLength: Int

    public init(decimalSeparator: Character = ".", maximumSourceLength: Int = 512) {
        self.decimalSeparator = decimalSeparator
        self.maximumSourceLength = maximumSourceLength
    }

    public func evaluate(_ source: String) throws -> Decimal {
        guard !source.isEmpty, source.count <= maximumSourceLength else {
            throw source.isEmpty ? CalculatorError.malformedExpression : CalculatorError.inputTooLong
        }
        var state = ParserState(tokens: try tokenize(source))
        let result = try state.parseExpression()
        guard state.isAtEnd else { throw CalculatorError.malformedExpression }
        return try validate(result)
    }

    public func apply(
        _ operation: CalculatorBinaryOperator,
        lhs: Decimal,
        rhs: Decimal
    ) throws -> Decimal {
        let result: Decimal
        switch operation {
        case .add:
            result = lhs + rhs
        case .subtract:
            result = lhs - rhs
        case .multiply:
            result = lhs * rhs
        case .divide:
            guard rhs != 0 else { throw CalculatorError.divideByZero }
            result = lhs / rhs
        case .power:
            result = try power(lhs, rhs)
        }
        return try validate(result)
    }

    private func tokenize(_ source: String) throws -> [Token] {
        let characters = Array(source)
        var tokens: [Token] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }

            if character.wholeNumberValue != nil || character == decimalSeparator {
                let start = index
                var hasSeparator = false
                while index < characters.count {
                    let current = characters[index]
                    if current.wholeNumberValue != nil {
                        index += 1
                    } else if current == decimalSeparator, !hasSeparator {
                        hasSeparator = true
                        index += 1
                    } else {
                        break
                    }
                }
                var numberText = String(characters[start..<index])
                if decimalSeparator != "." {
                    numberText = numberText.replacingOccurrences(
                        of: String(decimalSeparator),
                        with: "."
                    )
                }
                guard numberText != ".",
                      let value = Decimal(string: numberText, locale: Self.posixLocale) else {
                    throw CalculatorError.malformedExpression
                }
                tokens.append(.number(value))
                continue
            }

            switch character {
            case "+": tokens.append(.binary(.add))
            case "-", "−": tokens.append(.binary(.subtract))
            case "*", "×": tokens.append(.binary(.multiply))
            case "/", "÷": tokens.append(.binary(.divide))
            case "^": tokens.append(.binary(.power))
            case "(": tokens.append(.leftParenthesis)
            case ")": tokens.append(.rightParenthesis)
            default: throw CalculatorError.malformedExpression
            }
            index += 1
        }

        guard !tokens.isEmpty else { throw CalculatorError.malformedExpression }
        return tokens
    }

    private func power(_ base: Decimal, _ exponent: Decimal) throws -> Decimal {
        let exponentNumber = NSDecimalNumber(decimal: exponent)
        let integerExponent = exponentNumber.intValue
        if Decimal(integerExponent) == exponent {
            guard integerExponent >= -512, integerExponent <= 512 else {
                throw CalculatorError.overflow
            }
            if integerExponent == 0 { return 1 }
            if integerExponent < 0, base == 0 { throw CalculatorError.divideByZero }

            var result: Decimal = 1
            var factor = base
            var remaining = abs(integerExponent)
            while remaining > 0 {
                if remaining % 2 == 1 {
                    result = try validate(result * factor)
                }
                remaining /= 2
                if remaining > 0 {
                    factor = try validate(factor * factor)
                }
            }
            return integerExponent < 0 ? try validate(1 / result) : result
        }

        let baseValue = NSDecimalNumber(decimal: base).doubleValue
        let exponentValue = exponentNumber.doubleValue
        let result = Foundation.pow(baseValue, exponentValue)
        guard result.isFinite, !result.isNaN else { throw CalculatorError.domainError }
        return try validate(Decimal(result))
    }

    private func validate(_ value: Decimal) throws -> Decimal {
        let number = NSDecimalNumber(decimal: value)
        guard number != NSDecimalNumber.notANumber, number.doubleValue.isFinite else {
            throw CalculatorError.overflow
        }
        return value
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private enum Token: Equatable {
        case number(Decimal)
        case binary(CalculatorBinaryOperator)
        case leftParenthesis
        case rightParenthesis
    }

    private struct ParserState {
        let tokens: [Token]
        var index = 0

        var isAtEnd: Bool { index == tokens.count }

        mutating func parseExpression() throws -> Decimal {
            try parseAddition()
        }

        private mutating func parseAddition() throws -> Decimal {
            var value = try parseMultiplication()
            while let operation = match(.add, .subtract) {
                let rhs = try parseMultiplication()
                value = try ExpressionParser().apply(operation, lhs: value, rhs: rhs)
            }
            return value
        }

        private mutating func parseMultiplication() throws -> Decimal {
            var value = try parsePower()
            while let operation = match(.multiply, .divide) {
                let rhs = try parsePower()
                value = try ExpressionParser().apply(operation, lhs: value, rhs: rhs)
            }
            return value
        }

        private mutating func parsePower() throws -> Decimal {
            var value = try parseUnary()
            if match(.power) != nil {
                let rhs = try parsePower()
                value = try ExpressionParser().apply(.power, lhs: value, rhs: rhs)
            }
            return value
        }

        private mutating func parseUnary() throws -> Decimal {
            if match(.add) != nil {
                return try parseUnary()
            }
            if match(.subtract) != nil {
                return -(try parseUnary())
            }
            return try parsePrimary()
        }

        private mutating func parsePrimary() throws -> Decimal {
            guard index < tokens.count else { throw CalculatorError.malformedExpression }
            switch tokens[index] {
            case .number(let value):
                index += 1
                return value
            case .leftParenthesis:
                index += 1
                let value = try parseExpression()
                guard index < tokens.count, tokens[index] == .rightParenthesis else {
                    throw CalculatorError.malformedExpression
                }
                index += 1
                return value
            case .binary, .rightParenthesis:
                throw CalculatorError.malformedExpression
            }
        }

        private mutating func match(
            _ operations: CalculatorBinaryOperator...
        ) -> CalculatorBinaryOperator? {
            guard index < tokens.count,
                  case .binary(let operation) = tokens[index],
                  operations.contains(operation) else {
                return nil
            }
            index += 1
            return operation
        }
    }
}
