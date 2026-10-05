"""Source wiring checks; executable timing/state cases run with Swift on Apple CI."""

from pathlib import Path
import unittest

ROOT = Path(__file__).parent
HOST = (ROOT / 'CVLPHostView.swift').read_text(encoding='utf-8')
GATE = (ROOT / 'CVLPSyntheticHandoffGate.swift').read_text(encoding='utf-8')
PREP = (ROOT / 'prepare-upstream.py').read_text(encoding='utf-8')


def section(start, end):
    begin = HOST.index(start)
    return HOST[begin:HOST.index(end, begin + len(start))]


class SyntheticHandoffTests(unittest.TestCase):
    def test_explicit_one_shot_synthetic_only_entry(self):
        entry = section('func holdSyntheticGuest()', 'private func heldGuestIsLive()')
        for guard in ('guard !signalExperimentAttempted', 'CVLPFrameworkGuestMode',
                      'guest.isVerificationSignalProbeAvailable', 'gate.accepts(token: startupToken)',
                      'gate.phase == .running',
                      'UIApplication.shared.isProtectedDataAvailable', 'guest.requestVerificationSignal(SIGSTOP)'):
            self.assertIn(guard, entry)
        probe = section('func startVerificationSignalProbe()', 'private func finishVerificationSignalProbe(')
        self.assertIn('guard !signalExperimentAttempted', probe)
        self.assertIn('signalExperimentAttempted = true', probe)
        self.assertLess(entry.index('handoffGate.begin'), entry.index('beginBackgroundTask'))
        appearance = section('}.onAppear {', '\n    }\n}')
        self.assertNotIn('holdSyntheticGuest', appearance)

    def test_fixed_deadline_and_expiration_before_acquisition_returns(self):
        entry = section('func holdSyntheticGuest()', 'private func heldGuestIsLive()')
        self.assertIn('ContinuousClock.Instant', GATE)
        self.assertIn('maximumDuration: Duration = .seconds(120)', GATE)
        self.assertIn('deadline = now.advanced(by: Self.maximumDuration)', GATE)
        self.assertIn('expiry.markExpired()', entry)
        self.assertIn('identifier != .invalid && !expiry.isExpired', entry)
        self.assertIn('handoffClock.now.duration(to: deadline)', entry)
        self.assertIn('self.handoffToken == token', entry)

    def test_same_surface_stays_mounted_but_inaccessible(self):
        self.assertIn('model.locked && !model.holdingSyntheticGuest && !reportVisible', HOST)
        self.assertIn('.opacity(model.holdingSyntheticGuest ? 0 : 1)', HOST)
        self.assertIn('.allowsHitTesting(!model.holdingSyntheticGuest)', HOST)
        self.assertIn('.accessibilityHidden(model.holdingSyntheticGuest)', HOST)
        entry = section('func holdSyntheticGuest()', 'private func heldGuestIsLive()')
        self.assertNotIn('showingGuest = false', entry)
        self.assertNotIn('guest.revoke()', entry)
        self.assertIn('gate.revoke()', entry)
        self.assertIn('UIHostingController(rootView: CVLPSyntheticHoldCover(model: self))', HOST)

    def test_manual_fresh_biometrics_without_vault_authority(self):
        auth = section('func authenticateAndResumeSyntheticGuest()', 'func continueAuthenticatedSyntheticGuest()')
        self.assertIn('let authentication = LAContext()', auth)
        self.assertIn('deviceOwnerAuthenticationWithBiometrics', auth)
        self.assertIn('handoffAuthenticationContext === authentication', auth)
        self.assertIn('case .awaitingActivation:', auth)
        self.assertIn('case .failed, .expired, .backgrounded:', auth)
        self.assertNotIn('VaultKey', auth)
        self.assertIn('does not release Vault keys', auth)
        self.assertNotIn('resumeAuthenticatedSyntheticGuest()', auth)

    def test_background_during_auth_and_protected_data_always_terminal(self):
        background = section('@objc private func background(', '@objc private func protectedDataWillBecomeUnavailable(')
        self.assertIn('handoffGate.phase == .holding && heldGuestIsLive()', background)
        self.assertIn('lock(reason:', background)
        protection = section('@objc private func protectedDataWillBecomeUnavailable(', '@objc private func active(')
        self.assertIn('lock(reason: "protected-data loss")', protection)
        self.assertNotIn('if holdingSyntheticGuest', protection)
        active = section('@objc private func active(', 'private func cover()')
        self.assertIn('guard UIApplication.shared.applicationState == .active else { return }', active)
        self.assertIn('handoffGate.phase == .awaitingActivation', active)
        self.assertIn('activateAfterAuthentication', active)
        self.assertNotIn('resumeAuthenticatedSyntheticGuest()', active)
        self.assertIn('Button("Resume authenticated test") { model.continueAuthenticatedSyntheticGuest() }', HOST)
        manual = section('func continueAuthenticatedSyntheticGuest()', 'private func resumeAuthenticatedSyntheticGuest()')
        self.assertIn('guard canContinueAuthenticatedGuest else { return }', manual)
        self.assertIn('resumeAuthenticatedSyntheticGuest()', manual)

    def test_resume_guard_and_terminal_cleanup_order(self):
        resume = section('private func resumeAuthenticatedSyntheticGuest()', 'private func cancelSyntheticHandoff()')
        self.assertIn('heldGuestIsLive()', resume)
        self.assertIn('guestAttached: guest.viewController.viewIfLoaded?.window != nil', resume)
        self.assertLess(resume.index('prepareContinue'), resume.index('requestVerificationSignal(SIGCONT)'))
        self.assertLess(resume.index('continueRequestAccepted'), resume.index('holdingSyntheticGuest = false'))
        self.assertIn('lock(reason:', resume)
        cancel = section('private func cancelSyntheticHandoff()', 'func lock(reason:')
        self.assertLess(cancel.index('handoffGate.revoke()'), cancel.index('handoffAuthenticationContext?.invalidate()'))
        self.assertIn('handoffToken = nil', cancel)
        self.assertIn('handoffDeadlineWorkItem?.cancel()', cancel)
        self.assertIn('endBackgroundTask(identifier)', cancel)
        lock = section('func lock(reason:', '@objc private func inactive(')
        self.assertLess(lock.index('cancelSyntheticHandoff()'), lock.index('guest.revoke()'))

    def test_no_real_runtime_enablement_and_request_only_claims(self):
        runtime = (ROOT.parent / 'native-social-integration/IntegrationApp.swift').read_text(encoding='utf-8')
        self.assertIn('IntegrationRuntime: NativeGuestCooperativePauseRuntime', runtime)
        self.assertNotIn('requestNativeSignalDiagnostic(SIGSTOP)', runtime)
        self.assertNotIn('IntegrationRuntime: NativeGuestVerificationRuntime', runtime)
        self.assertIn('Suspension and media stop remain unproved', HOST)
        self.assertIn('CVLPSyntheticHandoffGate.swift', PREP)
        workflow = (ROOT.parent.parent / '.github/workflows/native-social-liveprocess-device.yml').read_text(encoding='utf-8')
        self.assertIn('test_synthetic_handoff.swift', workflow)
        self.assertIn('xcrun swiftc -warnings-as-errors', workflow)


if __name__ == '__main__':
    unittest.main()
