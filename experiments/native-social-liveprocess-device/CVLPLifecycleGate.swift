import Foundation

/// A small, UI-independent gate for serializing session startup and revocation.
public struct CVLPLifecycleGate {
    public enum Phase: Equatable {
        case locked
        case preparing
        case launching
        case running
    }

    public private(set) var generation: UInt64
    public private(set) var phase: Phase

    public init() {
        generation = 0
        phase = .locked
    }

    // Allows the command-line fixture to exercise the terminal counter boundary.
    init(generation: UInt64) {
        self.generation = generation
        phase = .locked
    }

    /// Starts one preparation attempt, if the gate is locked and can issue a fresh token.
    public mutating func begin() -> UInt64? {
        guard phase == .locked, advanceGeneration() else {
            return nil
        }

        phase = .preparing
        return generation
    }

    /// Accepts the current preparation result and permits launch only when it is ready.
    @discardableResult
    public mutating func prepared(token: UInt64, ready: Bool) -> Bool {
        guard phase == .preparing, token == generation else {
            return false
        }

        guard ready else {
            phase = .locked
            _ = advanceGeneration()
            return false
        }

        phase = .launching
        return true
    }

    /// Marks the current launch as running.
    @discardableResult
    public mutating func attached(token: UInt64) -> Bool {
        guard phase == .launching, token == generation else {
            return false
        }

        phase = .running
        return true
    }

    /// Revokes all outstanding work and returns the gate to its locked phase.
    public mutating func revoke() {
        phase = .locked
        _ = advanceGeneration()
    }

    /// Reports whether a token belongs to the current, non-locked generation.
    public func accepts(token: UInt64) -> Bool {
        token == generation && phase != .locked
    }

    /// Advances without wrapping; at UInt64.max no later generation can be issued.
    @discardableResult
    private mutating func advanceGeneration() -> Bool {
        guard generation < UInt64.max else {
            return false
        }

        generation += 1
        return true
    }
}
