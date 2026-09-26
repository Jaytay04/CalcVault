import Foundation

/// A completed, ordinary calculator operation suitable for history display.
///
/// History records intentionally contain only the expression, its displayed
/// result, and presentation metadata. The store has no persistence layer and
/// does not model authentication or secret-entry state.
public struct CalculatorHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let expression: String
    public let result: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        expression: String,
        result: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.expression = expression
        self.result = result
        self.createdAt = createdAt
    }
}

/// An in-memory, bounded history of completed calculator operations.
///
/// The backing array is maintained newest-first. IDs are generated once when
/// an entry is appended and remain stable until that entry is removed.
public final class CalculatorHistoryStore {
    public let capacity: Int

    private var entries: [CalculatorHistoryEntry] = []

    public init(capacity: Int = 100) {
        precondition(capacity > 0, "Calculator history capacity must be positive")
        self.capacity = capacity
    }

    /// The current history in display order, newest first.
    public var newestFirst: [CalculatorHistoryEntry] {
        entries
    }

    public var count: Int {
        entries.count
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    /// Returns a snapshot of the current history in newest-first order.
    public func read() -> [CalculatorHistoryEntry] {
        entries
    }

    /// Appends a completed operation and returns its stable history record.
    /// If the capacity is full, the oldest record is evicted.
    @discardableResult
    public func append(
        expression: String,
        result: String,
        createdAt: Date = Date()
    ) -> CalculatorHistoryEntry {
        let entry = CalculatorHistoryEntry(
            expression: expression,
            result: result,
            createdAt: createdAt
        )
        entries.insert(entry, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
        return entry
    }

    /// Finds a record for inspection without changing its position or ID.
    public func inspect(id: UUID) -> CalculatorHistoryEntry? {
        entries.first { $0.id == id }
    }

    /// Finds the complete record used to repopulate the calculator for reuse.
    /// Reuse is a read-only lookup and does not append or reorder history.
    public func lookupForReuse(id: UUID) -> CalculatorHistoryEntry? {
        inspect(id: id)
    }

    /// Removes one record, returning whether a matching ID was present.
    @discardableResult
    public func delete(id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }
        entries.remove(at: index)
        return true
    }

    /// Removes every history record. This affects only this in-memory history.
    public func clearAll() {
        entries.removeAll(keepingCapacity: true)
    }
}
