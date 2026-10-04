import Foundation

@main
struct SyntheticHandoffGateTests {
    static func main() {
        let clock = ContinuousClock()
        let start = clock.now
        testInvalidLeaseIsTerminal(start: start)
        testLeaseExpiryAtAcquisitionIsTerminal(start: start)
        testForegroundAndProtectedDataAreRequired(start: start)
        testAuthMayCompleteBeforeActivation(start: start)
        testAuthFailureProtectionLossAndBackground(start: start)
        testStaleAuthAndDeadlineAreRejected(start: start)
        testDeadlineDoesNotResetWhileAwaitingActivation(start: start)
        testDuplicateAndDetachedActionsAreRejected(start: start)
        print("Synthetic handoff gate fixtures passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    private static func holdingGate(start: ContinuousClock.Instant) -> (CVLPSyntheticHandoffGate, UInt64) {
        var gate = CVLPSyntheticHandoffGate()
        guard let token = gate.begin(now: start, foreground: true, protectedDataAvailable: true) else {
            fatalError("valid foreground hold did not begin")
        }
        expect(gate.deadline.map { $0 == start.advanced(by: .seconds(120)) } == true,
               "deadline is fixed at 120 seconds")
        expect(gate.leaseAcquired(token: token, valid: true, now: start, protectedDataAvailable: true),
               "valid background task lease is accepted")
        expect(gate.prepareStop(token: token, now: start, foreground: true,
                                protectedDataAvailable: true, guestAttached: true),
               "attached synthetic guest permits one stop request")
        expect(gate.stopRequestAccepted(token: token, now: start), "stop request is recorded as submitted")
        return (gate, token)
    }

    private static func testInvalidLeaseIsTerminal(start: ContinuousClock.Instant) {
        var gate = CVLPSyntheticHandoffGate()
        let token = gate.begin(now: start, foreground: true, protectedDataAvailable: true)
        expect(token != nil, "deadline starts before lease acquisition")
        expect(!gate.leaseAcquired(token: token!, valid: false, now: start, protectedDataAvailable: true),
               "invalid lease is refused")
        expect(gate.phase == .revoked && !gate.leaseAvailable, "invalid lease revokes the handoff")
        expect(!gate.prepareStop(token: token!, now: start, foreground: true,
                                 protectedDataAvailable: true, guestAttached: true),
               "invalid lease cannot submit SIGSTOP")
        expect(gate.begin(now: start, foreground: true, protectedDataAvailable: true) == nil,
               "invalid lease attempt cannot be retried")
    }

    private static func testLeaseExpiryAtAcquisitionIsTerminal(start: ContinuousClock.Instant) {
        var gate = CVLPSyntheticHandoffGate()
        guard let token = gate.begin(now: start, foreground: true, protectedDataAvailable: true) else {
            fatalError("lease-expiry fixture did not begin")
        }
        let deadline = start.advanced(by: .seconds(120))
        expect(!gate.leaseAcquired(token: token, valid: true, now: deadline, protectedDataAvailable: true),
               "a lease returned at the fixed deadline is rejected")
        expect(gate.phase == .revoked && !gate.leaseAvailable, "expired acquisition revokes the handoff")
    }

    private static func testForegroundAndProtectedDataAreRequired(start: ContinuousClock.Instant) {
        var inactive = CVLPSyntheticHandoffGate()
        expect(inactive.begin(now: start, foreground: false, protectedDataAvailable: true) == nil,
               "inactive app cannot begin a hold")
        var unprotected = CVLPSyntheticHandoffGate()
        expect(unprotected.begin(now: start, foreground: true, protectedDataAvailable: false) == nil,
               "protected-data loss blocks a hold")
    }

    private static func testAuthMayCompleteBeforeActivation(start: ContinuousClock.Instant) {
        let held = holdingGate(start: start)
        var gate = held.0
        let token = held.1
        guard let attempt = gate.beginAuthentication(token: token, now: start, foreground: true,
                                                      protectedDataAvailable: true) else {
            fatalError("fresh auth attempt did not begin")
        }
        expect(gate.completeAuthentication(token: token, attempt: attempt, succeeded: true, now: start,
                                            applicationActive: false, backgrounded: false,
                                            protectedDataAvailable: true) == .awaitingActivation,
               "successful Face ID result waits for app activation")
        expect(gate.activateAfterAuthentication(token: token, now: start, applicationActive: true,
                                                 backgrounded: false, protectedDataAvailable: true),
               "active notification consumes pending auth once")
        expect(!gate.activateAfterAuthentication(token: token, now: start, applicationActive: true,
                                                  backgrounded: false, protectedDataAvailable: true),
               "duplicate activation cannot authorize another resume")
        expect(gate.prepareContinue(token: token, now: start, foreground: true,
                                    protectedDataAvailable: true, guestAttached: true),
               "accepted auth permits one attached continuation request")
        expect(gate.continueRequestAccepted(token: token, now: start, foreground: true,
                                             protectedDataAvailable: true),
               "continuation submission ends the held state")
        expect(gate.phase == .resumed && !gate.leaseAvailable, "successful resume releases the lease")
    }

    private static func testAuthFailureProtectionLossAndBackground(start: ContinuousClock.Instant) {
        let failed = holdingGate(start: start)
        var cancelled = failed.0
        guard let cancelledAttempt = cancelled.beginAuthentication(token: failed.1, now: start, foreground: true,
                                                                    protectedDataAvailable: true) else {
            fatalError("cancel fixture auth did not begin")
        }
        expect(cancelled.completeAuthentication(token: failed.1, attempt: cancelledAttempt, succeeded: false,
                                                now: start, applicationActive: false, backgrounded: false,
                                                protectedDataAvailable: true) == .failed,
               "cancelled or failed biometric authentication is rejected")
        expect(cancelled.phase == .revoked, "failed auth revokes the held guest state")

        let protected = holdingGate(start: start)
        var lostProtection = protected.0
        guard let protectedAttempt = lostProtection.beginAuthentication(token: protected.1, now: start,
                                                                         foreground: true,
                                                                         protectedDataAvailable: true) else {
            fatalError("protected-data fixture auth did not begin")
        }
        expect(lostProtection.completeAuthentication(token: protected.1, attempt: protectedAttempt,
                                                     succeeded: true, now: start, applicationActive: false,
                                                     backgrounded: false, protectedDataAvailable: false) == .expired,
               "protected-data loss during auth is terminal")
        expect(lostProtection.phase == .revoked, "protected-data loss revokes the hold")

        let backgrounded = holdingGate(start: start)
        var genuineBackground = backgrounded.0
        guard let backgroundAttempt = genuineBackground.beginAuthentication(token: backgrounded.1, now: start,
                                                                             foreground: true,
                                                                             protectedDataAvailable: true) else {
            fatalError("background fixture auth did not begin")
        }
        expect(genuineBackground.completeAuthentication(token: backgrounded.1, attempt: backgroundAttempt,
                                                        succeeded: true, now: start, applicationActive: false,
                                                        backgrounded: true, protectedDataAvailable: true) == .backgrounded,
               "a successful callback after genuine backgrounding cannot resume")
        expect(genuineBackground.phase == .revoked, "background during pending auth revokes the hold")
    }

    private static func testStaleAuthAndDeadlineAreRejected(start: ContinuousClock.Instant) {
        let staleHeld = holdingGate(start: start)
        var stale = staleHeld.0
        let staleToken = staleHeld.1
        guard let attempt = stale.beginAuthentication(token: staleToken, now: start, foreground: true,
                                                         protectedDataAvailable: true) else {
            fatalError("stale fixture auth did not begin")
        }
        stale.revoke(token: staleToken)
        let revokedGeneration = stale.generation
        expect(stale.completeAuthentication(token: staleToken, attempt: attempt, succeeded: true, now: start,
                                               applicationActive: true, backgrounded: false,
                                               protectedDataAvailable: true) == .stale,
               "late auth callback is ignored after revoke")
        expect(stale.generation == revokedGeneration && stale.phase == .revoked,
               "stale auth cannot mutate revoked state")

        let expiredHeld = holdingGate(start: start)
        var expired = expiredHeld.0
        let expiredToken = expiredHeld.1
        guard let expiredAttempt = expired.beginAuthentication(token: expiredToken, now: start, foreground: true,
                                                                  protectedDataAvailable: true) else {
            fatalError("expiry fixture auth did not begin")
        }
        let deadline = start.advanced(by: .seconds(120))
        expect(expired.completeAuthentication(token: expiredToken, attempt: expiredAttempt, succeeded: true,
                                                now: deadline, applicationActive: true, backgrounded: false,
                                                protectedDataAvailable: true) == .expired,
               "auth callback at the fixed deadline fails closed")
        expect(expired.phase == .revoked, "deadline expiry revokes the handoff")
    }

    private static func testDeadlineDoesNotResetWhileAwaitingActivation(start: ContinuousClock.Instant) {
        let held = holdingGate(start: start)
        var gate = held.0
        let token = held.1
        let originalDeadline = gate.deadline
        let authTime = start.advanced(by: .seconds(10))
        guard let attempt = gate.beginAuthentication(token: token, now: authTime, foreground: true,
                                                      protectedDataAvailable: true) else {
            fatalError("activation-timing fixture auth did not begin")
        }
        expect(gate.completeAuthentication(token: token, attempt: attempt, succeeded: true, now: authTime,
                                            applicationActive: false, backgrounded: false,
                                            protectedDataAvailable: true) == .awaitingActivation,
               "successful result waits without extending the hold")
        expect(gate.deadline == originalDeadline, "authentication does not reset the fixed deadline")
        let beforeDeadline = start.advanced(by: .seconds(119))
        expect(gate.activateAfterAuthentication(token: token, now: beforeDeadline, applicationActive: true,
                                                 backgrounded: false, protectedDataAvailable: true),
               "activation before the original deadline can consume pending auth")
        expect(gate.deadline == originalDeadline && gate.isLive(token: token, now: beforeDeadline),
               "waiting for activation preserves the original deadline")
    }

    private static func testDuplicateAndDetachedActionsAreRejected(start: ContinuousClock.Instant) {
        let held = holdingGate(start: start)
        var gate = held.0
        let token = held.1
        expect(!gate.prepareStop(token: token, now: start, foreground: true,
                                 protectedDataAvailable: true, guestAttached: true),
               "SIGSTOP preparation is one-shot")
        expect(gate.beginAuthentication(token: token, now: start, foreground: true,
                                        protectedDataAvailable: true) != nil,
               "first authentication attempt is accepted")
        expect(gate.beginAuthentication(token: token, now: start, foreground: true,
                                        protectedDataAvailable: true) == nil,
               "duplicate authentication attempt is rejected")
        let attempt = gate.completeAuthentication(token: token, attempt: 1, succeeded: true, now: start,
                                                  applicationActive: true, backgrounded: false,
                                                  protectedDataAvailable: true)
        expect(attempt == .readyToResume, "active successful auth is immediately ready")
        expect(!gate.prepareContinue(token: token, now: start, foreground: true,
                                     protectedDataAvailable: true, guestAttached: false),
               "detached guest cannot be continued")
        expect(gate.prepareContinue(token: token, now: start, foreground: true,
                                    protectedDataAvailable: true, guestAttached: true),
               "attached guest can be continued")
        expect(!gate.prepareContinue(token: token, now: start, foreground: true,
                                     protectedDataAvailable: true, guestAttached: true),
               "SIGCONT preparation is one-shot")
    }
}
