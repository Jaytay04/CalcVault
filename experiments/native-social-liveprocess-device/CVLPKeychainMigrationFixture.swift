import Foundation
import LocalAuthentication
import Security

/// Disposable fixtures only. Never uses production services, accounts, or key bytes.
enum CVLPKeychainMigrationFixture {
    static func prepare() -> [String: Any] {
#if targetEnvironment(simulator)
        return ["ready": false, "summary": "Synthetic migration: SKIPPED on simulator; device authentication required."]
#else
        let identity = CVLPProbe.migrationIdentity()
        guard let source = identity["source"], let destination = identity["destination"],
              source != destination else {
            return ["ready": false, "summary": "Synthetic migration: INCONCLUSIVE (signed groups unavailable)."]
        }
        let service = "org.example.calcvault.migration-probe." + UUID().uuidString
        let context = LAContext()
        context.localizedReason = "Verify disposable biometric migration test items."
        defer { context.invalidate() }
        let store = SecurityKeychainMigrationStore(context: context)
        let migration = KeychainGroupMigration(store: store)
        var step = "starting"
        do {
            let items = [
                KeychainMigrationItem(service: service, account: "metadata-v1", protection: .whenUnlockedDeviceOnly),
                KeychainMigrationItem(service: service, account: "biometric-root-v1", protection: .biometryCurrentSet)
            ]
            for item in items {
                step = item.account + " seed"
                var bytes = Data(count: 32)
                let status = bytes.withUnsafeMutableBytes { buffer in
                    SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
                }
                guard status == errSecSuccess else { throw FixtureFailure.random }
                try store.insert(bytes, item: item, accessGroup: source)
                step = item.account + " source readback"
                guard try store.read(item, accessGroup: source) == bytes else { throw FixtureFailure.readback }
                step = item.account + " migration"
                guard try migration.move(item, from: source, to: destination) == .moved else { throw FixtureFailure.outcome }
                step = item.account + " retry"
                guard try migration.move(item, from: source, to: destination) == .alreadyMoved else { throw FixtureFailure.outcome }
            }
            step = "biometric-root-v1 unauthenticated read"
            context.invalidate()
            let unauthenticated = LAContext()
            unauthenticated.interactionNotAllowed = true
            defer { unauthenticated.invalidate() }
            do {
                _ = try SecurityKeychainMigrationStore(context: unauthenticated).read(items[1], accessGroup: destination)
                throw FixtureFailure.protection
            } catch KeychainGroupMigrationError.unexpectedStatus(let status) where status == errSecInteractionNotAllowed {
                // The host can read after authentication, but a fresh noninteractive context cannot.
            }
            return ["ready": true, "service": service, "source": source, "destination": destination,
                    "summary": "Synthetic migration: metadata and biometric-root READY; destination byte-match verified before old-copy removal; retry alreadyMoved; unauthenticated biometric read BLOCKED. No production credentials used."]
        } catch {
            // Step names are fixed synthetic labels. Never interpolate arbitrary Security errors or bytes.
            let reason: String
            if let migrationError = error as? KeychainGroupMigrationError {
                reason = String(describing: migrationError)
            } else {
                reason = "fixture verification failed"
            }
            return ["ready": false, "summary": "Synthetic migration: INCONCLUSIVE at " + step + " (" + reason + "); guest launch blocked. No production credentials used."]
        }
#endif
    }

    private enum FixtureFailure: Error { case random, readback, outcome, protection }
}
