import Foundation

public struct CalculatorFormatter: Sendable {
    public let decimalSeparator: Character
    public let maximumDisplayCharacters: Int

    public init(decimalSeparator: Character = ".", maximumDisplayCharacters: Int = 16) {
        self.decimalSeparator = decimalSeparator
        self.maximumDisplayCharacters = maximumDisplayCharacters
    }

    public func format(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        guard number != NSDecimalNumber.notANumber, number.doubleValue.isFinite else {
            return "Error"
        }

        var text = number.stringValue
        if text == "-0" { text = "0" }
        if text.count > maximumDisplayCharacters {
            text = scientific(number.doubleValue)
        }
        return localized(text)
    }

    public func formatScientific(_ value: Double) -> String {
        guard value.isFinite else { return "Error" }
        if value == 0 { return "0" }
        let plain = String(format: "%.12g", locale: Self.posixLocale, value)
        return localized(plain)
    }

    public func canonicalizeInput(_ input: String) -> String? {
        var canonical = input
        if decimalSeparator != "." {
            canonical = canonical.replacingOccurrences(of: String(decimalSeparator), with: ".")
        }
        let characters = Array(canonical)
        guard !characters.isEmpty else { return nil }
        var separatorCount = 0
        for (index, character) in characters.enumerated() {
            if character == "-" {
                guard index == 0 else { return nil }
            } else if character == "." {
                separatorCount += 1
                guard separatorCount == 1 else { return nil }
            } else if !character.isNumber {
                return nil
            }
        }
        guard canonical != "-", canonical != ".", canonical != "-." else { return nil }
        guard Decimal(string: canonical, locale: Self.posixLocale) != nil else { return nil }
        return canonical
    }

    private func scientific(_ value: Double) -> String {
        guard value != 0 else { return "0" }
        let exponent = Int(floor(log10(abs(value))))
        let mantissa = value / pow(10, Double(exponent))
        let rounded = (mantissa * 1_000_000_000).rounded() / 1_000_000_000
        return "\(NSDecimalNumber(value: rounded).stringValue)e\(exponent)"
    }

    private func localized(_ text: String) -> String {
        guard decimalSeparator != "." else { return text }
        return text.replacingOccurrences(of: ".", with: String(decimalSeparator))
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")
}
