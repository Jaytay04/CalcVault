import Foundation
import LocalAuthentication
import XCTest
@testable import CalcVault

final class HostOnlyKeychainStorageTests: XCTestCase {
    private let teamPrefix = "ABCDE12345"
    private let baseBundleIdentifier = "com.jaylintaylor.calcvault"
    private let suffix = "sidestore.fixture"

    func testLegacyCopiesAreDetectedInEverySupportedGroupForEachProtection() throws {
        let groups = try makeSideStoreGroups()

        for protection in [KeychainMigrationProtection.whenUnlockedDeviceOnly, .biometryCurrentSet] {
            for presentGroup in groups.legacyGroups {
                let backend = MemoryHostOnlyKeychainBackend()
                let item = makeItem(protection: protection)
                backend.seed(Data("legacy fixture".utf8), item: item, group: presentGroup)
                let storage = makeStorage(groups: groups, backend: backend)

                XCTAssertThrowsError(try storage.assertNoLegacyCopies([item])) { error in
                    XCTAssertEqual(error as? HostOnlyKeychainStorageError, .legacyCredentialPresent)
                }
                XCTAssertEqual(
                    backend.operations.filter { $0.kind == .contains }.map(\.group),
                    groups.legacyGroups
                )
                XCTAssertTrue(backend.operations.allSatisfy { $0.item == item })
                XCTAssertFalse(backend.operations.contains { $0.group == groups.hostOnly })
                XCTAssertTrue(backend.operations.allSatisfy { $0.kind == .contains })
            }
        }
    }

    func testLegacyCopyIsRejectedWhenMatchingHostOnlyCopyAlsoExists() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem()
        let data = Data("same identity fixture".utf8)
        backend.seed(data, item: item, group: groups.legacyGroups[0])
        backend.seed(data, item: item, group: groups.hostOnly)
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertThrowsError(try storage.assertNoLegacyCopies([item])) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .legacyCredentialPresent)
        }

        XCTAssertEqual(backend.operations.filter { $0.kind == .contains }.map(\.group), groups.legacyGroups)
        XCTAssertFalse(backend.operations.contains { $0.group == groups.hostOnly })
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.legacyGroups[0])], data)
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.hostOnly)], data)
    }

    func testAllAbsentInventoryChecksEveryIdentityAndLegacyGroupWithoutReadsOrMutation() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let items = [makeItem(account: "first"), makeItem(account: "second", protection: .biometryCurrentSet)]
        var groupResolutionCalls = 0
        var backendContexts: [LAContext?] = []
        let storage = HostOnlyKeychainStorage(
            groups: {
                groupResolutionCalls += 1
                return groups
            },
            backend: { context in
                backendContexts.append(context)
                return backend
            }
        )

        XCTAssertNoThrow(try storage.assertNoLegacyCopies(items))

        XCTAssertEqual(groupResolutionCalls, 1)
        XCTAssertEqual(backendContexts.count, 1)
        XCTAssertNil(backendContexts[0])
        let queries = backend.operations.filter { $0.kind == .contains }
        XCTAssertEqual(queries.count, items.count * groups.legacyGroups.count)
        XCTAssertEqual(
            queries.map { "\($0.item.service)|\($0.item.account)|\($0.group)" },
            items.flatMap { item in groups.legacyGroups.map { "\(item.service)|\(item.account)|\($0)" } }
        )
        XCTAssertTrue(backend.operations.allSatisfy { $0.kind == .contains })
        XCTAssertFalse(backend.operations.contains { $0.group == groups.hostOnly })
        XCTAssertTrue(backend.values.isEmpty)
    }

    func testInvalidInventoriesFailBeforeGroupResolutionOrBackendConstruction() throws {
        let duplicateIdentityWithDifferentProtection = [
            makeItem(service: "com.example.exact", account: "root"),
            makeItem(service: "com.example.exact", account: "root", protection: .biometryCurrentSet)
        ]
        let invalidInventories: [[KeychainMigrationItem]] = [
            [],
            [makeItem(service: "", account: "account")],
            [makeItem(service: "service", account: "")],
            duplicateIdentityWithDifferentProtection
        ]

        for items in invalidInventories {
            let backend = MemoryHostOnlyKeychainBackend()
            var groupResolutionCalls = 0
            var backendFactoryCalls = 0
            let storage = HostOnlyKeychainStorage(
                groups: {
                    groupResolutionCalls += 1
                    return try self.makeSingleLegacyGroups()
                },
                backend: { _ in
                    backendFactoryCalls += 1
                    return backend
                }
            )

            XCTAssertThrowsError(try storage.assertNoLegacyCopies(items)) { error in
                XCTAssertEqual(error as? HostOnlyKeychainStorageError, .invalidInventory)
            }
            XCTAssertEqual(groupResolutionCalls, 0)
            XCTAssertEqual(backendFactoryCalls, 0)
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }

    func testContainmentStatusFailurePropagatesWithoutTreatingItemAsAbsent() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem()
        backend.failContainsFor = ScopedCredential(item: item, group: groups.legacyGroups[0])
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertThrowsError(try storage.assertNoLegacyCopies([item])) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .unexpectedStatus(-50))
        }

        XCTAssertEqual(backend.operations.map(\.kind), [.contains])
        XCTAssertTrue(backend.values.isEmpty)
    }

    func testIdentityResolutionFailurePreventsBackendConstruction() throws {
        let backend = MemoryHostOnlyKeychainBackend()
        var backendFactoryCalls = 0
        let storage = HostOnlyKeychainStorage(
            groups: { throw HostOnlyKeychainStorageError.identityUnavailable },
            backend: { _ in
                backendFactoryCalls += 1
                return backend
            }
        )

        XCTAssertThrowsError(try storage.assertNoLegacyCopies([makeItem()])) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .identityUnavailable)
        }

        XCTAssertEqual(backendFactoryCalls, 0)
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testPreflightRescansInsteadOfCachingAnEarlierAbsence() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem()
        var groupResolutionCalls = 0
        let storage = HostOnlyKeychainStorage(
            groups: {
                groupResolutionCalls += 1
                return groups
            },
            backend: { _ in backend }
        )

        XCTAssertNoThrow(try storage.assertNoLegacyCopies([item]))
        backend.seed(Data("appeared after first scan".utf8), item: item, group: groups.legacyGroups[1])
        XCTAssertThrowsError(try storage.assertNoLegacyCopies([item])) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .legacyCredentialPresent)
        }

        XCTAssertEqual(groupResolutionCalls, 2)
        XCTAssertEqual(backend.operations.filter { $0.kind == .contains }.count, 4)
    }

    func testUnrelatedLegacyItemRemainsUntouchedByPreflight() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let requestedItem = makeItem(account: "requested")
        let unrelatedItem = makeItem(account: "unrelated")
        let unrelatedData = Data("unrelated fixture".utf8)
        backend.seed(unrelatedData, item: unrelatedItem, group: groups.legacyGroups[0])
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertNoThrow(try storage.assertNoLegacyCopies([requestedItem]))

        XCTAssertEqual(backend.values[ScopedCredential(item: unrelatedItem, group: groups.legacyGroups[0])], unrelatedData)
        XCTAssertTrue(backend.operations.allSatisfy { $0.kind == .contains && $0.item == requestedItem })
        XCTAssertEqual(backend.operations.map(\.group), groups.legacyGroups)
    }

    func testGuestBoundaryRejectsMissingRequiredCredential() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let required = makeItem(account: "required")
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertThrowsError(try storage.assertGuestCredentialBoundary(required: [required], optional: [])) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .invalidItem)
        }

        XCTAssertEqual(backend.operations.filter { $0.kind == .validateProtection }.map(\.item), [required])
        XCTAssertTrue(backend.operations.allSatisfy { $0.kind == .contains || $0.kind == .validateProtection })
    }

    func testGuestBoundaryRejectsPresentOptionalCredentialWithInvalidProtection() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let required = makeItem(account: "required")
        let optional = makeItem(account: "optional")
        backend.seed(Data("required fixture".utf8), item: required, group: groups.hostOnly)
        backend.seed(Data("optional fixture".utf8), item: optional, group: groups.hostOnly)
        backend.invalidProtectionFor.insert(ScopedCredential(item: optional, group: groups.hostOnly))
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertThrowsError(try storage.assertGuestCredentialBoundary(required: [required], optional: [optional])) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .protectionMismatch)
        }

        XCTAssertEqual(backend.operations.filter { $0.kind == .validateProtection }.map(\.item), [required, optional])
        XCTAssertTrue(backend.operations.allSatisfy { $0.kind == .contains || $0.kind == .validateProtection })
    }

    func testGuestBoundaryRejectsLegacyCopyEvenWhenHostDestinationIsValid() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem(account: "required")
        let data = Data("fixture".utf8)
        backend.seed(data, item: item, group: groups.legacyGroups[0])
        backend.seed(data, item: item, group: groups.hostOnly)
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertThrowsError(try storage.assertGuestCredentialBoundary(required: [item], optional: [])) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .legacyCredentialPresent)
        }

        XCTAssertEqual(backend.operations.filter { $0.kind == .contains }.map(\.group), groups.legacyGroups)
        XCTAssertFalse(backend.operations.contains { $0.kind == .validateProtection })
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.legacyGroups[0])], data)
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.hostOnly)], data)
    }

    func testGuestBoundaryPropagatesProtectionQueryStatusFailure() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let required = makeItem(account: "required")
        backend.seed(Data("required fixture".utf8), item: required, group: groups.hostOnly)
        backend.failValidationFor = ScopedCredential(item: required, group: groups.hostOnly)
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertThrowsError(try storage.assertGuestCredentialBoundary(required: [required], optional: [])) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .unexpectedStatus(-51))
        }

        XCTAssertTrue(backend.operations.allSatisfy { $0.kind == .contains || $0.kind == .validateProtection })
        XCTAssertEqual(backend.operations.filter { $0.kind == .validateProtection }.count, 1)
    }

    func testGuestBoundaryDiagnosticDistinguishesGroupResolution() throws {
        let backend = MemoryHostOnlyKeychainBackend()
        let storage = HostOnlyKeychainStorage(
            groups: { throw HostOnlyKeychainStorageError.identityUnavailable },
            backend: { _ in backend }
        )

        XCTAssertThrowsError(try storage.assertGuestCredentialBoundary(
            required: [makeItem()],
            optional: [],
            diagnosticErrors: true
        )) { error in
            XCTAssertEqual(
                (error as? NativeGuestCredentialBoundaryFailure)?.diagnosticCode,
                "native-guest-boundary.group-resolution.identity-unavailable"
            )
        }
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testGuestBoundaryDiagnosticIdentifiesInvalidInventory() throws {
        let backend = MemoryHostOnlyKeychainBackend()
        var groupResolutionCalls = 0
        let storage = HostOnlyKeychainStorage(
            groups: {
                groupResolutionCalls += 1
                return try self.makeSingleLegacyGroups()
            },
            backend: { _ in backend }
        )

        XCTAssertThrowsError(try storage.assertGuestCredentialBoundary(
            required: [],
            optional: [makeItem()],
            diagnosticErrors: true
        )) { error in
            XCTAssertEqual(
                (error as? NativeGuestCredentialBoundaryFailure)?.diagnosticCode,
                "native-guest-boundary.inventory.invalid-inventory"
            )
        }
        XCTAssertEqual(groupResolutionCalls, 0)
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testGuestBoundaryDiagnosticDistinguishesLegacyPresenceFromQueryFailure() throws {
        let groups = try makeSideStoreGroups()
        let item = makeItem(account: "required")

        let presentBackend = MemoryHostOnlyKeychainBackend()
        presentBackend.seed(Data("legacy fixture".utf8), item: item, group: groups.legacyGroups[0])
        let presentStorage = makeStorage(groups: groups, backend: presentBackend)
        XCTAssertThrowsError(try presentStorage.assertGuestCredentialBoundary(
            required: [item], optional: [], diagnosticErrors: true
        )) { error in
            XCTAssertEqual(
                (error as? NativeGuestCredentialBoundaryFailure)?.diagnosticCode,
                "native-guest-boundary.legacy-presence.item-0.group-0.legacy-credential-present"
            )
        }
        XCTAssertTrue(presentBackend.operations.allSatisfy { $0.kind == .contains })

        let failedBackend = MemoryHostOnlyKeychainBackend()
        failedBackend.failContainsFor = ScopedCredential(item: item, group: groups.legacyGroups[1])
        let failedStorage = makeStorage(groups: groups, backend: failedBackend)
        XCTAssertThrowsError(try failedStorage.assertGuestCredentialBoundary(
            required: [item], optional: [], diagnosticErrors: true
        )) { error in
            XCTAssertEqual(
                (error as? NativeGuestCredentialBoundaryFailure)?.diagnosticCode,
                "native-guest-boundary.legacy-presence.item-0.group-1.status:-50"
            )
        }
        XCTAssertTrue(failedBackend.operations.allSatisfy { $0.kind == .contains })
    }

    func testGuestBoundaryDiagnosticDistinguishesRequiredAndOptionalProtectionFailures() throws {
        let groups = try makeSideStoreGroups()
        let existingRequired = makeItem(account: "existing-required")
        let missingRequired = makeItem(account: "missing-required")
        let missingBackend = MemoryHostOnlyKeychainBackend()
        missingBackend.seed(Data("required fixture".utf8), item: existingRequired, group: groups.hostOnly)
        let missingStorage = makeStorage(groups: groups, backend: missingBackend)

        XCTAssertThrowsError(try missingStorage.assertGuestCredentialBoundary(
            required: [existingRequired, missingRequired], optional: [], diagnosticErrors: true
        )) { error in
            XCTAssertEqual(
                (error as? NativeGuestCredentialBoundaryFailure)?.diagnosticCode,
                "native-guest-boundary.required-protection.item-1.invalid-item"
            )
        }
        XCTAssertTrue(missingBackend.operations.allSatisfy {
            $0.kind == .contains || $0.kind == .validateProtection
        })

        let required = makeItem(account: "required")
        let optional = makeItem(account: "optional")
        let optionalBackend = MemoryHostOnlyKeychainBackend()
        optionalBackend.seed(Data("required fixture".utf8), item: required, group: groups.hostOnly)
        optionalBackend.failValidationFor = ScopedCredential(item: optional, group: groups.hostOnly)
        let optionalStorage = makeStorage(groups: groups, backend: optionalBackend)

        XCTAssertThrowsError(try optionalStorage.assertGuestCredentialBoundary(
            required: [required], optional: [optional], diagnosticErrors: true
        )) { error in
            XCTAssertEqual(
                (error as? NativeGuestCredentialBoundaryFailure)?.diagnosticCode,
                "native-guest-boundary.optional-protection.item-0.status:-51"
            )
        }
        XCTAssertTrue(optionalBackend.operations.allSatisfy {
            $0.kind == .contains || $0.kind == .validateProtection
        })
    }

    func testGuestBoundaryDiagnosticDoesNotExposeUnknownErrorOrCredentialIdentity() throws {
        let groups = try makeSideStoreGroups()
        let item = makeItem(service: "synthetic-service-secret", account: "synthetic-account-secret")
        let unknownErrorText = "synthetic-underlying-error-secret"
        let backend = MemoryHostOnlyKeychainBackend()
        backend.containsFailure = SecretDiagnosticError(message: unknownErrorText)
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertThrowsError(try storage.assertGuestCredentialBoundary(
            required: [item], optional: [], diagnosticErrors: true
        )) { error in
            let failure = error as? NativeGuestCredentialBoundaryFailure
            XCTAssertEqual(
                failure?.diagnosticCode,
                "native-guest-boundary.legacy-presence.item-0.group-0.unclassified"
            )
            let diagnosticCode = failure?.diagnosticCode ?? ""
            for secret in [unknownErrorText, item.service, item.account] + groups.legacyGroups + [groups.hostOnly] {
                XCTAssertFalse(diagnosticCode.contains(secret))
            }
        }
        XCTAssertTrue(backend.operations.allSatisfy { $0.kind == .contains })
    }

    func testGuestBoundaryRejectsInvalidInventoryBeforeGroupResolutionOrBackendConstruction() throws {
        let groups = try makeSideStoreGroups()
        let invalidInventories: [([KeychainMigrationItem], [KeychainMigrationItem])] = [
            ([], [makeItem(account: "optional")]),
            ([makeItem(service: "", account: "required")], []),
            ([makeItem(account: "same")], [makeItem(account: "same", protection: .biometryCurrentSet)])
        ]

        for (required, optional) in invalidInventories {
            let backend = MemoryHostOnlyKeychainBackend()
            var groupResolutionCalls = 0
            var backendFactoryCalls = 0
            let storage = HostOnlyKeychainStorage(
                groups: {
                    groupResolutionCalls += 1
                    return groups
                },
                backend: { _ in
                    backendFactoryCalls += 1
                    return backend
                }
            )

            XCTAssertThrowsError(try storage.assertGuestCredentialBoundary(required: required, optional: optional)) { error in
                XCTAssertEqual(error as? HostOnlyKeychainStorageError, .invalidInventory)
            }
            XCTAssertEqual(groupResolutionCalls, 0)
            XCTAssertEqual(backendFactoryCalls, 0)
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }

    func testGuestBoundaryAllowsAbsentOptionalAndUsesMetadataOnlyRescans() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let required = makeItem(account: "required")
        let optional = makeItem(account: "optional")
        let requiredData = Data("required fixture".utf8)
        backend.seed(requiredData, item: required, group: groups.hostOnly)
        var groupResolutionCalls = 0
        var backendContexts: [LAContext?] = []
        let storage = HostOnlyKeychainStorage(
            groups: {
                groupResolutionCalls += 1
                return groups
            },
            backend: { context in
                backendContexts.append(context)
                return backend
            }
        )

        XCTAssertNoThrow(try storage.assertGuestCredentialBoundary(required: [required], optional: [optional]))
        backend.seed(Data("legacy appeared".utf8), item: optional, group: groups.legacyGroups[1])
        XCTAssertThrowsError(try storage.assertGuestCredentialBoundary(required: [required], optional: [optional])) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .legacyCredentialPresent)
        }

        XCTAssertEqual(groupResolutionCalls, 2)
        XCTAssertEqual(backendContexts.count, 2)
        for context in backendContexts { XCTAssertNil(context) }
        XCTAssertEqual(backend.operations.filter { $0.kind == .contains }.count, 8)
        XCTAssertEqual(backend.operations.filter { $0.kind == .validateProtection }.map(\.item), [required, optional])
        XCTAssertTrue(backend.operations.allSatisfy { $0.kind == .contains || $0.kind == .validateProtection })
        XCTAssertEqual(backend.values[ScopedCredential(item: required, group: groups.hostOnly)], requiredData)
        XCTAssertEqual(backend.values[ScopedCredential(item: optional, group: groups.legacyGroups[1])], Data("legacy appeared".utf8))
    }

    func testNewWriteUsesOnlyHostOnlyGroupAndPreservesProtection() throws {
        let groups = try makeSingleLegacyGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem(protection: .whenUnlockedDeviceOnly)
        let data = Data("new fixture".utf8)
        let storage = makeStorage(groups: groups, backend: backend)

        try storage.write(data, item: item)

        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.hostOnly)], data)
        XCTAssertNil(backend.values[ScopedCredential(item: item, group: groups.legacy)])
        XCTAssertEqual(
            backend.operations.filter { $0.kind == .contains }.map(\.group),
            [groups.legacy, groups.hostOnly]
        )
        XCTAssertEqual(
            backend.operations.filter { $0.kind == .insert }.map { ($0.item, $0.group) }.map { "\($0.0.service)|\($0.0.account)|\($0.1)" },
            ["com.example.fixture|credential|\(groups.hostOnly)"]
        )
        XCTAssertEqual(backend.operations.first(where: { $0.kind == .insert })?.item.protection, .whenUnlockedDeviceOnly)
    }

    func testNewWriteRejectsExistingCredentialInEveryLegacyAndHostOnlyGroup() throws {
        let groups = try makeSideStoreGroups()
        let item = makeItem()
        let original = Data("existing fixture".utf8)

        for existingGroup in groups.legacyGroups + [groups.hostOnly] {
            let backend = MemoryHostOnlyKeychainBackend()
            backend.seed(original, item: item, group: existingGroup)
            let storage = makeStorage(groups: groups, backend: backend)

            XCTAssertThrowsError(try storage.write(Data("replacement".utf8), item: item)) { error in
                XCTAssertEqual(error as? HostOnlyKeychainStorageError, .duplicateItem)
            }
            XCTAssertEqual(backend.values, [ScopedCredential(item: item, group: existingGroup): original])
            XCTAssertFalse(backend.operations.contains { $0.kind == .insert })
        }
    }

    func testReadMigratesBaseOnlyLegacyCredentialAfterSideStoreSuffixDiscovery() throws {
        let runtimeBundleID = "\(baseBundleIdentifier).\(suffix)"
        let observedDefaultGroup = "\(teamPrefix).\(baseBundleIdentifier)"
        let groups = try KeychainGroupDiscovery.deriveGroups(
            defaultGroup: observedDefaultGroup,
            bundleIdentifier: runtimeBundleID
        )
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem()
        let data = Data("base legacy fixture".utf8)
        backend.seed(data, item: item, group: "\(teamPrefix).\(baseBundleIdentifier)")
        let unrelatedItem = makeItem(account: "unrelated")
        let unrelatedData = Data("unrelated fixture".utf8)
        backend.seed(unrelatedData, item: unrelatedItem, group: groups.legacy)
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertEqual(try storage.read(item), data)

        XCTAssertNil(backend.values[ScopedCredential(item: item, group: groups.legacy)])
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: "\(teamPrefix).\(baseBundleIdentifier)")], nil)
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.hostOnly)], data)
        XCTAssertEqual(backend.values[ScopedCredential(item: unrelatedItem, group: groups.legacy)], unrelatedData)
        XCTAssertEqual(groups.legacyGroups, ["\(teamPrefix).\(runtimeBundleID)", "\(teamPrefix).\(baseBundleIdentifier)"])
    }

    func testReadForwardsBiometricContextAndKeepsProtectionOnMigratedItem() throws {
        let groups = try makeSingleLegacyGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem(protection: .biometryCurrentSet)
        let data = Data("biometric fixture".utf8)
        backend.seed(data, item: item, group: groups.legacy)
        let context = LAContext()
        var forwardedContexts: [LAContext?] = []
        let storage = makeStorage(groups: groups, backend: backend) { forwardedContexts.append($0) }

        XCTAssertEqual(try storage.read(item, context: context), data)

        XCTAssertEqual(forwardedContexts.count, 1)
        XCTAssertTrue(forwardedContexts[0] === context)
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.hostOnly)], data)
        XCTAssertEqual(backend.operations.first(where: { $0.kind == .insert })?.item.protection, .biometryCurrentSet)
    }

    func testIdenticalCopiesAcrossLegacyAndHostGroupsDoNotOverwriteAndAreConsolidated() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem()
        let data = Data("same fixture".utf8)
        for group in groups.legacyGroups + [groups.hostOnly] {
            backend.seed(data, item: item, group: group)
        }
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertEqual(try storage.read(item), data)

        XCTAssertEqual(backend.values, [ScopedCredential(item: item, group: groups.hostOnly): data])
        XCTAssertFalse(backend.operations.contains { $0.kind == .insert })
        XCTAssertEqual(
            backend.operations.filter { $0.kind == .remove }.map(\.group),
            groups.legacyGroups
        )
    }

    func testConflictingLegacyGroupsFailBeforeAnyCopyOrDeletion() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem()
        let runtimeData = Data("runtime fixture".utf8)
        let baseData = Data("base fixture".utf8)
        backend.seed(runtimeData, item: item, group: groups.legacy)
        backend.seed(baseData, item: item, group: groups.legacyGroups[1])
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertThrowsError(try storage.read(item)) { error in
            XCTAssertEqual(error as? KeychainGroupMigrationError, .conflictingItems)
        }

        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.legacy)], runtimeData)
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.legacyGroups[1])], baseData)
        XCTAssertNil(backend.values[ScopedCredential(item: item, group: groups.hostOnly)])
        XCTAssertFalse(backend.operations.contains { $0.kind == .insert || $0.kind == .remove })
    }

    func testFailedCopyPreservesLegacyDataAndRetryCompletesMigration() throws {
        let groups = try makeSingleLegacyGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem()
        let data = Data("retry copy fixture".utf8)
        backend.seed(data, item: item, group: groups.legacy)
        backend.failNextInsert = true
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertThrowsError(try storage.read(item))
        XCTAssertEqual(backend.values, [ScopedCredential(item: item, group: groups.legacy): data])

        XCTAssertEqual(try storage.read(item), data)
        XCTAssertNil(backend.values[ScopedCredential(item: item, group: groups.legacy)])
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.hostOnly)], data)
    }

    func testFailedSourceDeletionKeepsBothCopiesAndRetryCompletesMigration() throws {
        let groups = try makeSingleLegacyGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem()
        let data = Data("retry delete fixture".utf8)
        backend.seed(data, item: item, group: groups.legacy)
        backend.failNextRemovalForGroups.insert(groups.legacy)
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertThrowsError(try storage.read(item))
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.legacy)], data)
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.hostOnly)], data)

        XCTAssertEqual(try storage.read(item), data)
        XCTAssertNil(backend.values[ScopedCredential(item: item, group: groups.legacy)])
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.hostOnly)], data)
    }

    func testMigrationRejectsConflictingDestinationWithoutChangingEitherCopy() throws {
        let groups = try makeSingleLegacyGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem()
        let legacyData = Data("legacy fixture".utf8)
        let hostData = Data("host fixture".utf8)
        backend.seed(legacyData, item: item, group: groups.legacy)
        backend.seed(hostData, item: item, group: groups.hostOnly)

        XCTAssertThrowsError(try KeychainGroupMigration(store: backend).move(
            item,
            from: groups.legacy,
            to: groups.hostOnly
        )) { error in
            XCTAssertEqual(error as? KeychainGroupMigrationError, .conflictingItems)
        }

        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.legacy)], legacyData)
        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.hostOnly)], hostData)
        XCTAssertFalse(backend.operations.contains { $0.kind == .insert || $0.kind == .remove })
    }

    func testReplaceMigratesThenUpdatesOnlyHostOnlyCredential() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem(protection: .whenUnlockedDeviceOnly)
        let original = Data("original fixture".utf8)
        let replacement = Data("replacement fixture".utf8)
        backend.seed(original, item: item, group: groups.legacyGroups[1])
        let unrelatedItem = makeItem(account: "unrelated")
        let unrelated = Data("unrelated fixture".utf8)
        backend.seed(unrelated, item: unrelatedItem, group: groups.legacy)
        let storage = makeStorage(groups: groups, backend: backend)

        try storage.replace(replacement, item: item)

        XCTAssertEqual(backend.values[ScopedCredential(item: item, group: groups.hostOnly)], replacement)
        XCTAssertNil(backend.values[ScopedCredential(item: item, group: groups.legacyGroups[1])])
        XCTAssertEqual(backend.values[ScopedCredential(item: unrelatedItem, group: groups.legacy)], unrelated)
        XCTAssertEqual(backend.operations.filter { $0.kind == .replace }.map(\.group), [groups.hostOnly])
        XCTAssertEqual(backend.operations.first(where: { $0.kind == .replace })?.item.protection, .whenUnlockedDeviceOnly)
    }

    func testReplaceOfAbsentCredentialFailsWithoutCreatingAnItem() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let storage = makeStorage(groups: groups, backend: backend)

        XCTAssertThrowsError(try storage.replace(Data("replacement".utf8), item: makeItem())) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .invalidItem)
        }

        XCTAssertTrue(backend.values.isEmpty)
        XCTAssertFalse(backend.operations.contains { $0.kind == .insert || $0.kind == .replace })
    }

    func testReplaceRejectsBiometricProtectionBeforeBackendAccess() throws {
        let groups = try makeSingleLegacyGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        var backendFactoryCalls = 0
        let storage = HostOnlyKeychainStorage(
            groups: { groups },
            backend: { _ in
                backendFactoryCalls += 1
                return backend
            }
        )

        XCTAssertThrowsError(try storage.replace(
            Data("replacement".utf8),
            item: makeItem(protection: .biometryCurrentSet)
        )) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .protectionMismatch)
        }

        XCTAssertEqual(backendFactoryCalls, 0)
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testExplicitDeleteRemovesOnlyRequestedItemFromEverySupportedGroup() throws {
        let groups = try makeSideStoreGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem()
        let unrelatedItem = makeItem(account: "unrelated")
        let targetData = Data("target fixture".utf8)
        let unrelatedData = Data("unrelated fixture".utf8)
        for group in groups.legacyGroups + [groups.hostOnly] {
            backend.seed(targetData, item: item, group: group)
            backend.seed(unrelatedData, item: unrelatedItem, group: group)
        }
        let storage = makeStorage(groups: groups, backend: backend)

        try storage.delete(item)

        XCTAssertTrue(groups.legacyGroups.concat(groups.hostOnly).allSatisfy {
            backend.values[ScopedCredential(item: item, group: $0)] == nil
        })
        for group in groups.legacyGroups + [groups.hostOnly] {
            XCTAssertEqual(backend.values[ScopedCredential(item: unrelatedItem, group: group)], unrelatedData)
        }
        let removals = backend.operations.filter { $0.kind == .remove }
        XCTAssertEqual(removals.map(\.group), groups.legacyGroups + [groups.hostOnly])
        XCTAssertTrue(removals.allSatisfy { $0.item == item })
    }

    func testInvalidGroupResolutionCausesNoBackendConstructionOrIO() throws {
        let backend = MemoryHostOnlyKeychainBackend()
        var backendFactoryCalls = 0
        let storage = HostOnlyKeychainStorage(
            groups: { throw HostOnlyKeychainStorageError.identityUnavailable },
            backend: { _ in
                backendFactoryCalls += 1
                return backend
            }
        )

        XCTAssertThrowsError(try storage.read(makeItem()))

        XCTAssertEqual(backendFactoryCalls, 0)
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testDiscoveryDerivesRuntimeAndBaseGroupsFromObservedPrefix() throws {
        let runtimeBundleID = "\(baseBundleIdentifier).\(suffix)"
        let observedDefaultGroup = "\(teamPrefix).\(baseBundleIdentifier)"

        let groups = try KeychainGroupDiscovery.deriveGroups(
            defaultGroup: observedDefaultGroup,
            bundleIdentifier: runtimeBundleID
        )

        XCTAssertEqual(groups.legacy, "\(teamPrefix).\(runtimeBundleID)")
        XCTAssertEqual(groups.legacyGroups, [
            "\(teamPrefix).\(runtimeBundleID)",
            "\(teamPrefix).\(baseBundleIdentifier)"
        ])
        XCTAssertEqual(groups.hostOnly, "\(teamPrefix).\(baseBundleIdentifier).hostonly")
    }

    func testDiscoveryFailsClosedForUnknownForeignOrAmbiguousIdentities() {
        let invalidIdentities = [
            ("TEAM.com.example.unknown", baseBundleIdentifier),
            ("\(teamPrefix).\(baseBundleIdentifier)", "com.example.foreign"),
            ("\(teamPrefix).\(baseBundleIdentifier)", "\(baseBundleIdentifier).hostonly")
        ]

        for (defaultGroup, bundleIdentifier) in invalidIdentities {
            XCTAssertThrowsError(try KeychainGroupDiscovery.deriveGroups(
                defaultGroup: defaultGroup,
                bundleIdentifier: bundleIdentifier
            )) { error in
                XCTAssertEqual(error as? HostOnlyKeychainStorageError, .identityUnavailable)
            }
        }
    }

    func testDiscoveryRequiresEveryPositiveControlAndCachesOnlySuccessfulResolution() throws {
        let state = DiscoveryState()
        let runtimeBundleID = "\(baseBundleIdentifier).\(suffix)"
        let observedDefaultGroup = "\(teamPrefix).\(baseBundleIdentifier)"
        let runtimeGroup = "\(teamPrefix).\(runtimeBundleID)"
        let baseGroup = "\(teamPrefix).\(baseBundleIdentifier)"
        let hostOnlyGroup = "\(teamPrefix).\(baseBundleIdentifier).hostonly"
        let expectedVerificationOrder = [runtimeGroup, baseGroup, hostOnlyGroup]
        let discovery = KeychainGroupDiscovery(
            defaultGroup: {
                state.defaultGroupCalls += 1
                if state.failDefaultGroup {
                    throw HostOnlyKeychainStorageError.identityUnavailable
                }
                return observedDefaultGroup
            },
            verifyGroup: { group in
                state.verifiedGroups.append(group)
                if group == hostOnlyGroup && !state.allowHostOnlyControl {
                    throw HostOnlyKeychainStorageError.unexpectedStatus(-31)
                }
            },
            bundleIdentifier: { runtimeBundleID }
        )

        XCTAssertThrowsError(try discovery.resolve()) { error in
            XCTAssertEqual(error as? HostOnlyKeychainStorageError, .unexpectedStatus(-31))
        }
        XCTAssertEqual(state.verifiedGroups, expectedVerificationOrder)

        state.allowHostOnlyControl = true
        let resolved = try discovery.resolve()
        state.failDefaultGroup = true
        XCTAssertEqual(try discovery.resolve(), resolved)

        XCTAssertEqual(resolved.legacyGroups, [runtimeGroup, baseGroup])
        XCTAssertEqual(resolved.hostOnly, hostOnlyGroup)
        XCTAssertEqual(state.defaultGroupCalls, 2)
        XCTAssertEqual(state.verifiedGroups, expectedVerificationOrder + expectedVerificationOrder)
    }

    func testCredentialWrappersUseInjectedHostOnlyStorageAndTheirProtectionPolicies() throws {
        let groups = try makeSingleLegacyGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let storage = makeStorage(groups: groups, backend: backend)
        let metadata = UnlockedDeviceKeychainStore(service: "com.example.metadata", storage: storage)
        let metadataData = Data("metadata fixture".utf8)

        try metadata.write(metadataData, account: "envelope")
        XCTAssertEqual(try metadata.read(account: "envelope"), metadataData)
        let metadataItem = makeItem(
            service: "com.example.metadata",
            account: "envelope",
            protection: .whenUnlockedDeviceOnly
        )
        XCTAssertEqual(backend.values[ScopedCredential(item: metadataItem, group: groups.hostOnly)], metadataData)
        XCTAssertTrue(backend.operations.filter { $0.kind == .insert }.allSatisfy {
            $0.group == groups.hostOnly && $0.item == metadataItem
        })
        XCTAssertTrue(backend.operations.filter { $0.kind == .read }.allSatisfy {
            (groups.legacyGroups.contains($0.group) || $0.group == groups.hostOnly) && $0.item == metadataItem
        })
        XCTAssertThrowsError(try metadata.write(Data("duplicate".utf8), account: "envelope")) { error in
            XCTAssertEqual(error as? Phase2CredentialStoreError, .duplicateItem)
        }

        let biometricBackend = MemoryHostOnlyKeychainBackend()
        let biometricStorage = makeStorage(groups: groups, backend: biometricBackend)
        let biometricStore = KeychainStore(service: "com.example.biometric", storage: biometricStorage)
        let biometricData = Data("biometric root fixture".utf8)
        let context = LAContext()
        var forwardedContexts: [LAContext?] = []
        let contextStorage = makeStorage(groups: groups, backend: biometricBackend) {
            forwardedContexts.append($0)
        }
        let contextStore = KeychainStore(service: "com.example.biometric", storage: contextStorage)

        try biometricStore.write(biometricData, account: "root")
        XCTAssertEqual(try contextStore.read(account: "root", context: context), biometricData)
        let biometricItem = makeItem(
            service: "com.example.biometric",
            account: "root",
            protection: .biometryCurrentSet
        )
        XCTAssertEqual(biometricBackend.values[ScopedCredential(item: biometricItem, group: groups.hostOnly)], biometricData)
        XCTAssertTrue(biometricBackend.operations.filter { $0.kind == .insert }.allSatisfy {
            $0.group == groups.hostOnly && $0.item == biometricItem
        })
        XCTAssertTrue(biometricBackend.operations.filter { $0.kind == .read }.allSatisfy {
            (groups.legacyGroups.contains($0.group) || $0.group == groups.hostOnly) && $0.item == biometricItem
        })
        XCTAssertEqual(forwardedContexts.count, 1)
        XCTAssertTrue(forwardedContexts[0] === context)
        XCTAssertThrowsError(try contextStore.write(Data("duplicate".utf8), account: "root")) { error in
            XCTAssertEqual(error as? KeychainStoreError, .duplicateItem)
        }
    }

    func testMigrationReportsAbsentAndAlreadyMovedWithoutMutation() throws {
        let groups = try makeSingleLegacyGroups()
        let backend = MemoryHostOnlyKeychainBackend()
        let item = makeItem()
        let migration = KeychainGroupMigration(store: backend)

        XCTAssertEqual(try migration.move(item, from: groups.legacy, to: groups.hostOnly), .absent)
        backend.seed(Data("host fixture".utf8), item: item, group: groups.hostOnly)
        XCTAssertEqual(try migration.move(item, from: groups.legacy, to: groups.hostOnly), .alreadyMoved)

        XCTAssertFalse(backend.operations.contains { $0.kind == .insert || $0.kind == .remove })
    }

    private func makeSingleLegacyGroups() throws -> KeychainAccessGroups {
        try KeychainAccessGroups(
            legacy: "\(teamPrefix).\(baseBundleIdentifier)",
            hostOnly: "\(teamPrefix).\(baseBundleIdentifier).hostonly"
        )
    }

    private func makeSideStoreGroups() throws -> KeychainAccessGroups {
        try KeychainAccessGroups(
            legacy: "\(teamPrefix).\(baseBundleIdentifier).\(suffix)",
            hostOnly: "\(teamPrefix).\(baseBundleIdentifier).hostonly",
            additionalLegacyGroups: ["\(teamPrefix).\(baseBundleIdentifier)"]
        )
    }

    private func makeItem(
        service: String = "com.example.fixture",
        account: String = "credential",
        protection: KeychainMigrationProtection = .whenUnlockedDeviceOnly
    ) -> KeychainMigrationItem {
        KeychainMigrationItem(service: service, account: account, protection: protection)
    }

    private func makeStorage(
        groups: KeychainAccessGroups,
        backend: MemoryHostOnlyKeychainBackend,
        contextObserver: @escaping (LAContext?) -> Void = { _ in }
    ) -> HostOnlyKeychainStorage {
        HostOnlyKeychainStorage(
            groups: { groups },
            backend: { context in
                contextObserver(context)
                return backend
            }
        )
    }
}

private struct ScopedCredential: Hashable {
    let item: KeychainMigrationItem
    let group: String
}

private enum BackendOperationKind: Equatable {
    case read
    case insert
    case remove
    case contains
    case validateProtection
    case replace
}

private struct BackendOperation {
    let kind: BackendOperationKind
    let item: KeychainMigrationItem
    let group: String
}

private final class MemoryHostOnlyKeychainBackend: HostOnlyKeychainBackend {
    var values: [ScopedCredential: Data] = [:]
    var operations: [BackendOperation] = []
    var failNextInsert = false
    var failNextRemovalForGroups: Set<String> = []
    var failContainsFor: ScopedCredential?
    var containsFailure: (any Error)?
    var failValidationFor: ScopedCredential?
    var invalidProtectionFor: Set<ScopedCredential> = []

    func seed(_ data: Data, item: KeychainMigrationItem, group: String) {
        values[ScopedCredential(item: item, group: group)] = data
    }

    private func matchingCredential(_ item: KeychainMigrationItem, group: String) -> ScopedCredential? {
        values.keys.first {
            $0.group == group && $0.item.service == item.service && $0.item.account == item.account
        }
    }

    func read(_ item: KeychainMigrationItem, accessGroup: String) throws -> Data? {
        operations.append(BackendOperation(kind: .read, item: item, group: accessGroup))
        return values[ScopedCredential(item: item, group: accessGroup)]
    }

    func insert(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws {
        operations.append(BackendOperation(kind: .insert, item: item, group: accessGroup))
        if failNextInsert {
            failNextInsert = false
            throw KeychainGroupMigrationError.unexpectedStatus(-41)
        }
        let credential = ScopedCredential(item: item, group: accessGroup)
        guard values[credential] == nil else { throw HostOnlyKeychainStorageError.duplicateItem }
        values[credential] = data
    }

    func remove(_ item: KeychainMigrationItem, accessGroup: String) throws {
        operations.append(BackendOperation(kind: .remove, item: item, group: accessGroup))
        if failNextRemovalForGroups.remove(accessGroup) != nil {
            throw KeychainGroupMigrationError.unexpectedStatus(-42)
        }
        values.removeValue(forKey: ScopedCredential(item: item, group: accessGroup))
    }

    func contains(_ item: KeychainMigrationItem, accessGroup: String) throws -> Bool {
        operations.append(BackendOperation(kind: .contains, item: item, group: accessGroup))
        if let containsFailure { throw containsFailure }
        if failContainsFor == ScopedCredential(item: item, group: accessGroup) {
            throw HostOnlyKeychainStorageError.unexpectedStatus(-50)
        }
        return matchingCredential(item, group: accessGroup) != nil
    }

    func validateProtection(_ item: KeychainMigrationItem, accessGroup: String) throws -> Bool {
        operations.append(BackendOperation(kind: .validateProtection, item: item, group: accessGroup))
        let expectedCredential = ScopedCredential(item: item, group: accessGroup)
        if failValidationFor == expectedCredential {
            throw HostOnlyKeychainStorageError.unexpectedStatus(-51)
        }
        guard let credential = matchingCredential(item, group: accessGroup) else { return false }
        guard credential.item.protection == item.protection,
              !invalidProtectionFor.contains(expectedCredential) else {
            throw HostOnlyKeychainStorageError.protectionMismatch
        }
        return true
    }

    func replace(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws {
        operations.append(BackendOperation(kind: .replace, item: item, group: accessGroup))
        let credential = ScopedCredential(item: item, group: accessGroup)
        guard values[credential] != nil else { throw HostOnlyKeychainStorageError.invalidItem }
        values[credential] = data
    }
}

private struct SecretDiagnosticError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class DiscoveryState {
    var defaultGroupCalls = 0
    var verifiedGroups: [String] = []
    var allowHostOnlyControl = false
    var failDefaultGroup = false
}

private extension Array where Element == String {
    func concat(_ value: String) -> [String] { self + [value] }
}
