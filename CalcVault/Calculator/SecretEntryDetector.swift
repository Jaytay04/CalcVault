import Foundation

/// The source of a numeric input event as observed by the calculator shell.
///
/// Only keypad and explicitly supported physical-keyboard digits are eligible
/// for the navigation sequence.  Every other source is deliberately named so
/// a caller cannot accidentally treat restored or pasted text as manual entry.
public enum SecretEntryInputSource: String, CaseIterable, Sendable {
    case manualKeypad
    case manualPhysicalKeyboard
    case pastedText
    case historyRecall
    case calculationResult
    case importedExpression

    fileprivate var isEligibleManualSource: Bool {
        switch self {
        case .manualKeypad, .manualPhysicalKeyboard:
            return true
        case .pastedText, .historyRecall, .calculationResult, .importedExpression:
            return false
        }
    }
}

/// Delimiters supported by the secret-entry state machine.
///
/// Equals is the only delimiter in the initial implementation.  Keeping it
/// typed prevents arbitrary calculator text from becoming an implicit trigger.
public enum SecretEntryDelimiter: String, Sendable {
    case equals = "="
}

public enum SecretEntryConfigurationError: Error, Equatable, Sendable {
    case sequenceLengthMustBeBetweenOneAndTwelve
    case sequenceMustContainASCIIDigitsOnly
}

public struct SecretEntryConfiguration: Sendable {
    fileprivate let sequenceBytes: [UInt8]
    public let delimiter: SecretEntryDelimiter

    public var digitCount: Int { sequenceBytes.count }

    /// Creates a configured detector.  There is intentionally no default
    /// sequence: enrollment must provide the owner's chosen value.
    public init(
        sequence: String,
        delimiter: SecretEntryDelimiter = .equals
    ) throws {
        let bytes = Array(sequence.utf8)
        guard (1...12).contains(bytes.count) else {
            throw SecretEntryConfigurationError.sequenceLengthMustBeBetweenOneAndTwelve
        }
        guard bytes.allSatisfy({ (48...57).contains($0) }) else {
            throw SecretEntryConfigurationError.sequenceMustContainASCIIDigitsOnly
        }
        self.sequenceBytes = bytes
        self.delimiter = delimiter
    }
}

/// Events from the calculator shell that can affect the navigation detector.
///
/// The detector has no access to calculator state, authentication, the vault,
/// WebKit, or Keychain.  The shell must explicitly report lifecycle and source
/// information so restored expressions cannot be mistaken for fresh typing.
public enum SecretEntryEvent: Sendable {
    case allClear
    case freshSession
    case digit(UInt8, source: SecretEntryInputSource)
    case numericEntry(String, source: SecretEntryInputSource)
    case delimiter(SecretEntryDelimiter)
    case unrelatedOperator
    case decimal
    case signTransformation
    case completedCalculation
    case timeout
    case backgrounded
    case locked
}

public enum SecretEntryResult: Equatable, Sendable {
    case ignored
    case reset
    case tracking
    case unlockRequested
}

/// A bounded, explicit state machine for the calculator navigation sequence.
///
/// It is intentionally a value type so the application coordinator can own it
/// and serialize mutations on the main actor.  The candidate is never exposed
/// and is kept only as ASCII digit bytes in memory while a fresh entry is in
/// progress.
public struct SecretEntryDetector: Sendable {
    public let configuration: SecretEntryConfiguration

    private enum State: Equatable, Sendable {
        case ready
        case collecting
        case waitingForFreshEntry
    }

    private var state: State = .ready
    private var candidate: [UInt8] = []

    public init(configuration: SecretEntryConfiguration) {
        self.configuration = configuration
    }

    /// Number of candidate digits currently buffered.  This is intentionally
    /// metadata only; the candidate's contents are never returned.
    public var candidateLength: Int {
        candidate.count
    }

    public var isCollecting: Bool {
        if case .collecting = state { return true }
        return false
    }

    /// Consumes one explicit calculator event and returns whether the shell
    /// should request authentication.  A matching delimiter is consumed here:
    /// callers must not forward that event to ordinary calculation/history.
    @discardableResult
    public mutating func receive(_ event: SecretEntryEvent) -> SecretEntryResult {
        switch event {
        case .allClear, .freshSession:
            armForFreshEntry()
            return .reset

        case let .digit(digit, source):
            guard source.isEligibleManualSource, (48...57).contains(digit) else {
                resetToWaitingState()
                return .reset
            }
            guard state == .ready || state == .collecting else {
                return .ignored
            }
            guard candidate.count < configuration.digitCount else {
                resetToWaitingState()
                return .reset
            }
            candidate.append(digit)
            state = .collecting
            return .tracking

        case let .numericEntry(_, source):
            // Numeric text arriving as a paste, result, recall, or import is
            // never eligible.  Even an explicit manual source here is rejected
            // because eligibility is granted one digit event at a time.
            guard source.isEligibleManualSource == false else {
                resetToWaitingState()
                return .reset
            }
            resetToWaitingState()
            return .reset

        case let .delimiter(delimiter):
            guard delimiter == configuration.delimiter,
                  state == .collecting else {
                return .ignored
            }
            let matches = Self.constantTimeEquals(candidate, configuration.sequenceBytes)
            resetToWaitingState()
            return matches ? .unlockRequested : .reset

        case .unrelatedOperator, .decimal, .signTransformation,
             .completedCalculation, .timeout, .backgrounded, .locked:
            resetToWaitingState()
            return .reset
        }
    }

    /// Constant-time byte comparison for bounded values.  The loop runs for
    /// the larger input length and folds the length difference into the result,
    /// so a mismatch does not return early on the first differing byte.
    public static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        let count = max(lhs.count, rhs.count)
        var difference = UInt64(lhs.count ^ rhs.count)
        if count > 0 {
            for index in 0..<count {
                let left = index < lhs.count ? lhs[index] : 0
                let right = index < rhs.count ? rhs[index] : 0
                difference |= UInt64(left ^ right)
            }
        }
        return difference == 0
    }

    private mutating func armForFreshEntry() {
        candidate.removeAll(keepingCapacity: true)
        state = .ready
    }

    private mutating func resetToWaitingState() {
        candidate.removeAll(keepingCapacity: true)
        state = .waitingForFreshEntry
    }
}
