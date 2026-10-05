import UIKit

/// A host-app allowance, not an extension entitlement or a promise of 120 seconds.
/// The coordinator independently enforces its monotonic deadline.
@MainActor
final class NativeGuestBackgroundLease: NativeGuestHandoffLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var expired = false
    private let expiration: @MainActor () -> Void

    init?(expiration: @escaping @MainActor () -> Void) {
        guard UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable else { return nil }
        self.expiration = expiration
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Native verification handoff") { [weak self] in
            // UIKit invokes the expiration handler synchronously on the main thread.
            MainActor.assumeIsolated { self?.expire() }
        }
        guard identifier != .invalid, !expired else {
            end()
            return nil
        }
    }

    var isValid: Bool { !expired && identifier != .invalid }

    var backgroundTimeRemainingSeconds: Double? {
        guard UIApplication.shared.applicationState == .background else { return nil }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        // Do not render a huge finite "unlimited" sentinel as an allowance.
        guard remaining.isFinite, remaining >= 0, remaining < 86_400 else { return nil }
        return remaining
    }

    func end() {
        let previous = identifier
        identifier = .invalid
        if previous != .invalid { UIApplication.shared.endBackgroundTask(previous) }
    }

    private func expire() {
        guard !expired else { return }
        expired = true
        // Revoke before returning from UIKit's expiration callback. The guest
        // is not allowed to survive until a later foreground timer check.
        expiration()
        end()
    }
}
