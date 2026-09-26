import Combine
import Foundation

@MainActor
public final class CalculatorViewModel: ObservableObject {
    @Published public private(set) var engine: CalculatorEngine
    @Published public private(set) var history: [CalculatorHistoryEntry] = []

    private let historyStore: CalculatorHistoryStore
    private var secretEntryDetector: SecretEntryDetector?
    private var authenticationRequest: (() -> Void)?
    private var lastSecretInputAt: Date?
    private let secretEntryTimeout: TimeInterval
    private let now: () -> Date

    public init(
        engine: CalculatorEngine = CalculatorEngine(),
        historyStore: CalculatorHistoryStore = CalculatorHistoryStore(),
        secretEntryTimeout: TimeInterval = 15,
        now: @escaping () -> Date = Date.init
    ) {
        self.engine = engine
        self.historyStore = historyStore
        self.secretEntryTimeout = secretEntryTimeout
        self.now = now
        history = historyStore.read()
    }

    public func configureSecretEntry(sequence: String, onAuthenticationRequest: @escaping () -> Void) throws {
        secretEntryDetector = SecretEntryDetector(
            configuration: try SecretEntryConfiguration(sequence: sequence)
        )
        authenticationRequest = onAuthenticationRequest
        lastSecretInputAt = nil
    }

    public func digit(_ value: Int, source: SecretEntryInputSource = .manualKeypad) {
        if let byte = String(value).utf8.first, (0...9).contains(value) {
            expireSecretEntryIfNeeded()
            _ = secretEntryDetector?.receive(.digit(byte, source: source))
            lastSecretInputAt = now()
        }
        engine.inputDigit(value)
    }

    public func decimal() {
        resetSecretEntry(.decimal)
        engine.inputDecimalPoint()
    }

    public func toggleSign() {
        resetSecretEntry(.signTransformation)
        engine.toggleSign()
    }

    public func percent() {
        resetSecretEntry(.unrelatedOperator)
        engine.percent()
    }

    public func deleteBackward() {
        resetSecretEntry(.unrelatedOperator)
        engine.deleteBackward()
    }

    public func clearEntry() {
        resetSecretEntry(.unrelatedOperator)
        engine.clearEntry()
    }

    public func allClear() {
        resetSecretEntry(.allClear)
        engine.allClear()
    }

    public func clear() {
        let isAllClear = engine.clearButtonTitle == "AC"
        resetSecretEntry(isAllClear ? .allClear : .unrelatedOperator)
        engine.clear()
    }

    public func binary(_ operation: CalculatorBinaryOperator) {
        resetSecretEntry(.unrelatedOperator)
        engine.inputBinaryOperator(operation)
    }

    public func openParenthesis() {
        resetSecretEntry(.unrelatedOperator)
        engine.openParenthesis()
    }

    public func closeParenthesis() {
        resetSecretEntry(.unrelatedOperator)
        engine.closeParenthesis()
    }

    public func scientific(_ function: CalculatorScientificFunction) {
        resetSecretEntry(.unrelatedOperator)
        engine.applyScientific(function)
    }

    public func constant(_ constant: CalculatorConstant) {
        resetSecretEntry(.unrelatedOperator)
        engine.inputConstant(constant)
    }

    public func memory(_ operation: CalculatorMemoryOperation) {
        resetSecretEntry(.unrelatedOperator)
        engine.performMemory(operation)
    }
    public func angle(_ unit: CalculatorAngleUnit) { engine.setAngleUnit(unit) }

    public func equals() {
        expireSecretEntryIfNeeded()
        if secretEntryDetector?.receive(.delimiter(.equals)) == .unlockRequested {
            lastSecretInputAt = nil
            engine.allClear()
            authenticationRequest?()
            return
        }
        engine.equals()
        captureCompletion()
        resetSecretEntry(.completedCalculation)
    }

    public func reuse(_ entry: CalculatorHistoryEntry) {
        _ = secretEntryDetector?.receive(.numericEntry(entry.result, source: .historyRecall))
        lastSecretInputAt = nil
        engine.reuseHistoryResult(entry.result)
    }

    public func prepareFreshSecretEntry() {
        engine.allClear()
        resetSecretEntry(.freshSession)
    }

    public func resetSecretEntryForBackground() {
        resetSecretEntry(.backgrounded)
    }

    public func resetSecretEntryForLock() {
        resetSecretEntry(.locked)
    }

    public func deleteHistory(_ entry: CalculatorHistoryEntry) {
        _ = historyStore.delete(id: entry.id)
        history = historyStore.read()
    }

    public func clearHistory() {
        historyStore.clearAll()
        history = []
    }

    private func captureCompletion() {
        guard let completion = engine.takeCompletion(), engine.error == nil else { return }
        historyStore.append(expression: completion.expression, result: completion.result)
        history = historyStore.read()
    }

    private func expireSecretEntryIfNeeded() {
        guard let lastSecretInputAt,
              now().timeIntervalSince(lastSecretInputAt) > secretEntryTimeout else {
            return
        }
        resetSecretEntry(.timeout)
    }

    private func resetSecretEntry(_ event: SecretEntryEvent) {
        _ = secretEntryDetector?.receive(event)
        lastSecretInputAt = nil
    }
}
