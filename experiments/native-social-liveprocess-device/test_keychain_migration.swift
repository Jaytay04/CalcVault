import Foundation

private enum StoreFault: Error, Equatable {
    case insertFailed
    case readFailed
    case removeFailed
}

private struct StoreKey: Hashable {
    let service: String
    let account: String
    let group: String

    init(_ item: KeychainMigrationItem, group: String) {
        service = item.service
        account = item.account
        self.group = group
    }
}

private struct StoreCall {
    let operation: String
    let item: KeychainMigrationItem
    let group: String
}

private final class FakeMigrationStore: KeychainMigrationStore {
    private(set) var values: [StoreKey: Data] = [:]
    private(set) var calls: [StoreCall] = []
    private(set) var insertedPolicies: [KeychainMigrationProtection] = []

    var failNextInsert = false
    var failNextRead = false
    var failNextRemove = false
    var corruptNextDestinationRead = false
    var mutateSourceOnInsert = false
    var changedSource = Data([0x22])
    var returnSuccessWithoutRemoving = false
    var removeAlsoRemovesDestination = false

    func seed(_ data: Data, item: KeychainMigrationItem, group: String) {
        values[StoreKey(item, group: group)] = data
    }

    func value(_ item: KeychainMigrationItem, group: String) -> Data? {
        values[StoreKey(item, group: group)]
    }

    var insertCount: Int {
        calls.filter { $0.operation == "insert" }.count
    }

    var removeCount: Int {
        calls.filter { $0.operation == "remove" }.count
    }

    func read(_ item: KeychainMigrationItem, accessGroup: String) throws -> Data? {
        calls.append(StoreCall(operation: "read", item: item, group: accessGroup))
        if failNextRead {
            failNextRead = false
            throw StoreFault.readFailed
        }
        let key = StoreKey(item, group: accessGroup)
        let storedValue = values[key]
        if accessGroup == "destination", corruptNextDestinationRead, storedValue != nil {
            corruptNextDestinationRead = false
            return Data([0xCC])
        }
        return storedValue
    }

    func insert(
        _ data: Data,
        item: KeychainMigrationItem,
        accessGroup: String
    ) throws {
        calls.append(StoreCall(operation: "insert", item: item, group: accessGroup))
        insertedPolicies.append(item.protection)
        if failNextInsert {
            failNextInsert = false
            throw StoreFault.insertFailed
        }

        let key = StoreKey(item, group: accessGroup)
        guard values[key] == nil else {
            throw StoreFault.insertFailed
        }
        values[key] = data

        if mutateSourceOnInsert {
            values[StoreKey(item, group: "source")] = changedSource
            mutateSourceOnInsert = false
        }
    }

    func remove(_ item: KeychainMigrationItem, accessGroup: String) throws {
        calls.append(StoreCall(operation: "remove", item: item, group: accessGroup))
        if failNextRemove {
            failNextRemove = false
            throw StoreFault.removeFailed
        }
        guard !returnSuccessWithoutRemoving else {
            return
        }

        values.removeValue(forKey: StoreKey(item, group: accessGroup))
        if removeAlsoRemovesDestination {
            values.removeValue(forKey: StoreKey(item, group: "destination"))
        }
    }
}

@main
private enum KeychainMigrationHarness {
    private static let sourceGroup = "source"
    private static let destinationGroup = "destination"
    private static let fixture = Data([0x10, 0x20, 0x30, 0x40])
    private static let item = KeychainMigrationItem(
        service: "fixture.migration.service",
        account: "fixture-migration-account",
        protection: .whenUnlockedDeviceOnly
    )

    private static var testCount = 0

    static func main() throws {
        try test("moves and verifies exact item") {
            let store = FakeMigrationStore()
            store.seed(fixture, item: item, group: sourceGroup)
            let outcome = try engine(store).move(item, from: sourceGroup, to: destinationGroup)

            check(outcome == .moved, "source item should be moved")
            check(store.value(item, group: sourceGroup) == nil, "source item should be absent")
            check(store.value(item, group: destinationGroup) == fixture, "destination bytes should match")
            check(store.insertedPolicies == [.whenUnlockedDeviceOnly], "source protection should be passed to insert")
            check(store.insertCount == 1 && store.removeCount == 1, "successful move should insert and remove once")
            check(store.calls.allSatisfy { $0.item == item }, "all operations should use the exact service and account")
            check(Set(store.calls.map(\.group)) == Set([sourceGroup, destinationGroup]), "all operations should be group-scoped")
            check(store.calls.first(where: { $0.operation == "remove" })?.group == sourceGroup, "only source group may be removed")
        }

        try test("forwards biometric-current-set protection to insert") {
            let store = FakeMigrationStore()
            let biometricItem = KeychainMigrationItem(
                service: "fixture.biometric-migration.service",
                account: "fixture-biometric-migration-account",
                protection: .biometryCurrentSet
            )
            store.seed(fixture, item: biometricItem, group: sourceGroup)

            let outcome = try engine(store).move(biometricItem, from: sourceGroup, to: destinationGroup)
            check(outcome == .moved, "biometric-protected item should be moved")
            check(store.insertedPolicies == [.biometryCurrentSet], "biometric-current-set policy should reach insert")
        }

        try test("returns absent when neither group has the item") {
            let store = FakeMigrationStore()
            let outcome = try engine(store).move(item, from: sourceGroup, to: destinationGroup)
            check(outcome == .absent, "empty groups should return absent")
            check(store.insertCount == 0 && store.removeCount == 0, "absent item should not mutate storage")
        }

        try test("returns already moved when only destination has the item") {
            let store = FakeMigrationStore()
            store.seed(fixture, item: item, group: destinationGroup)
            let outcome = try engine(store).move(item, from: sourceGroup, to: destinationGroup)
            check(outcome == .alreadyMoved, "destination-only item should return alreadyMoved")
            check(store.insertCount == 0 && store.removeCount == 0, "already moved item should not mutate storage")
        }

        try test("does not overwrite a conflicting destination") {
            let store = FakeMigrationStore()
            let otherValue = Data([0x90, 0x91])
            store.seed(fixture, item: item, group: sourceGroup)
            store.seed(otherValue, item: item, group: destinationGroup)

            try expectError(KeychainGroupMigrationError.conflictingItems) {
                try engine(store).move(item, from: sourceGroup, to: destinationGroup)
            }
            check(store.value(item, group: sourceGroup) == fixture, "conflict should preserve source")
            check(store.value(item, group: destinationGroup) == otherValue, "conflict should preserve destination")
            check(store.insertCount == 0 && store.removeCount == 0, "conflict should perform no mutations")
        }

        try test("preserves source when destination insert fails") {
            let store = FakeMigrationStore()
            store.seed(fixture, item: item, group: sourceGroup)
            store.failNextInsert = true

            try expectError(StoreFault.insertFailed) {
                try engine(store).move(item, from: sourceGroup, to: destinationGroup)
            }
            check(store.value(item, group: sourceGroup) == fixture, "insert failure should preserve source")
            check(store.value(item, group: destinationGroup) == nil, "failed insert should leave destination absent")
            check(store.removeCount == 0, "source should not be removed after insert failure")
        }

        try test("preserves source when destination readback differs") {
            let store = FakeMigrationStore()
            store.seed(fixture, item: item, group: sourceGroup)
            store.corruptNextDestinationRead = true

            try expectError(KeychainGroupMigrationError.destinationVerificationFailed) {
                try engine(store).move(item, from: sourceGroup, to: destinationGroup)
            }
            check(store.value(item, group: sourceGroup) == fixture, "failed readback should preserve source")
            check(store.removeCount == 0, "source should not be removed after failed readback")
        }

        try test("retry completes after source removal failure") {
            let store = FakeMigrationStore()
            store.seed(fixture, item: item, group: sourceGroup)
            store.failNextRemove = true

            try expectError(StoreFault.removeFailed) {
                try engine(store).move(item, from: sourceGroup, to: destinationGroup)
            }
            check(store.value(item, group: sourceGroup) == fixture, "failed removal should preserve source")
            check(store.value(item, group: destinationGroup) == fixture, "verified copy should remain after removal failure")

            let retryOutcome = try engine(store).move(item, from: sourceGroup, to: destinationGroup)
            check(retryOutcome == .moved, "retry should finish the interrupted migration")
            check(store.value(item, group: sourceGroup) == nil, "retry should remove the source")
            check(store.value(item, group: destinationGroup) == fixture, "retry should retain destination")
            check(store.insertCount == 1, "retry should not insert over the existing destination")
        }

        try test("detects a source change before removal") {
            let store = FakeMigrationStore()
            store.seed(fixture, item: item, group: sourceGroup)
            store.mutateSourceOnInsert = true

            try expectError(KeychainGroupMigrationError.sourceChanged) {
                try engine(store).move(item, from: sourceGroup, to: destinationGroup)
            }
            check(store.value(item, group: sourceGroup) == store.changedSource, "changed source should remain intact")
            check(store.value(item, group: destinationGroup) == fixture, "copied destination should remain intact")
            check(store.removeCount == 0, "changed source should not be removed")
        }

        try test("detects a removal that reports success without removing") {
            let store = FakeMigrationStore()
            store.seed(fixture, item: item, group: sourceGroup)
            store.returnSuccessWithoutRemoving = true

            try expectError(KeychainGroupMigrationError.sourceRemovalNotConfirmed) {
                try engine(store).move(item, from: sourceGroup, to: destinationGroup)
            }
            check(store.value(item, group: sourceGroup) == fixture, "unconfirmed removal should leave source")
            check(store.value(item, group: destinationGroup) == fixture, "destination should remain verified")
        }

        try test("detects destination loss after source removal") {
            let store = FakeMigrationStore()
            store.seed(fixture, item: item, group: sourceGroup)
            store.removeAlsoRemovesDestination = true

            try expectError(KeychainGroupMigrationError.destinationVerificationFailed) {
                try engine(store).move(item, from: sourceGroup, to: destinationGroup)
            }
            check(store.value(item, group: sourceGroup) == nil, "source removal already completed")
            check(store.value(item, group: destinationGroup) == nil, "lost destination should be reported")
        }

        try test("read failure performs no mutations") {
            let store = FakeMigrationStore()
            store.seed(fixture, item: item, group: sourceGroup)
            store.failNextRead = true

            try expectError(StoreFault.readFailed) {
                try engine(store).move(item, from: sourceGroup, to: destinationGroup)
            }
            check(store.value(item, group: sourceGroup) == fixture, "read failure should preserve source")
            check(store.insertCount == 0 && store.removeCount == 0, "read failure should perform no mutations")
        }

        try test("rejects invalid groups before any store access") {
            let store = FakeMigrationStore()
            try expectError(KeychainGroupMigrationError.invalidGroups) {
                try engine(store).move(item, from: sourceGroup, to: sourceGroup)
            }
            try expectError(KeychainGroupMigrationError.invalidGroups) {
                try engine(store).move(item, from: " \n", to: destinationGroup)
            }
            check(store.calls.isEmpty, "invalid groups should not access the store")
        }

        try test("rejects empty item identifiers before any store access") {
            let store = FakeMigrationStore()
            let invalidItem = KeychainMigrationItem(
                service: "",
                account: "fixture-account",
                protection: .biometryCurrentSet
            )
            try expectError(KeychainGroupMigrationError.invalidItem) {
                try engine(store).move(invalidItem, from: sourceGroup, to: destinationGroup)
            }
            check(store.calls.isEmpty, "invalid item should not access the store")
        }

        print("PASS \(testCount) keychain migration tests")
    }

    private static func engine(_ store: FakeMigrationStore) -> KeychainGroupMigration {
        KeychainGroupMigration(store: store)
    }

    private static func test(_ name: String, body: () throws -> Void) rethrows {
        try body()
        testCount += 1
        print("PASS \(name)")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            preconditionFailure("Keychain migration test failed: \(message)")
        }
    }

    private static func expectError<E: Error & Equatable>(
        _ expected: E,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            preconditionFailure("Expected an error from the migration operation")
        } catch let actual as E {
            check(actual == expected, "operation returned an unexpected error")
        } catch {
            preconditionFailure("Operation returned an unexpected error type")
        }
    }
}
