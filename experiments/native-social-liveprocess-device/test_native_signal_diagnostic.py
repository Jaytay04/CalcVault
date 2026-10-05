"""Source contracts for the separately gated native signal request diagnostic.

These checks do not execute an iOS target or establish OS suspension.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).parent
SESSION = (ROOT / 'CVLPGuestSession.m').read_text(encoding='utf-8')
PATCHER = (ROOT / 'prepare-lifecycle.py').read_text(encoding='utf-8')
APP = (ROOT.parent / 'native-social-integration/IntegrationApp.swift').read_text(encoding='utf-8')


def section(source, begin, end):
    return source.split(begin, 1)[1].split(end, 1)[0]


class NativeSignalDiagnosticTests(unittest.TestCase):
    def test_exact_original_target_and_typed_opt_in_required(self):
        identity = section(SESSION, '- (BOOL)nativeSignalDiagnosticIdentityIsVerified {',
                           '- (BOOL)nativeSignalDiagnosticRequestIsReady {')
        for guard in ('CVNativeSignalDiagnosticEnabled', 'CFBooleanGetTypeID()',
                      'CVLPFrameworkGuestMode', 'CVNativeGuestKind', 'tiktok47',
                      'CFBundleVersion', 'private-tiktok47-integration-24',
                      'cvlp-immutable-framework', 'integration-native-24',
                      'CVLPFrameworkGuestURL', 'CVLPGuestPropertyList',
                      'com.zhiliaoapp.musically', '470044', 'NativeGuest', '47.0.0'):
            self.assertIn(guard, identity)
        self.assertNotIn('syntheticnativeguest.app', identity)
        self.assertIn('return NO;', identity)

    def test_each_request_rechecks_identity_readiness_and_one_shot(self):
        ready = section(SESSION, '- (BOOL)nativeSignalDiagnosticRequestIsReady {',
                        '- (BOOL)isNativeSignalDiagnosticAvailable {')
        for guard in ('!self.revoked', 'self.sceneController.cvlpBeginCompleted',
                      'self.sceneController.cvlpObservedPID > 0',
                      'self.sceneController.cvlpObservedPID == self.observedPID',
                      '[self nativeSignalDiagnosticIdentityIsVerified]',
                      'self.sceneController.cvlpNativeSignalDiagnosticTargetVerified'):
            self.assertIn(guard, ready)
        request = section(SESSION, '- (BOOL)requestNativeSignalDiagnostic:(int)signal {',
                          '- (BOOL)requestVerificationSignal:(int)signal {')
        for guard in ('self.isNativeSignalDiagnosticAvailable',
                      'self.nativeSignalDiagnosticStopAttempted = YES',
                      '!self.nativeSignalDiagnosticStopSubmitted',
                      'self.nativeSignalDiagnosticContinueAttempted',
                      '[self nativeSignalDiagnosticRequestIsReady]'):
            self.assertIn(guard, request)
        self.assertLess(request.index('self.nativeSignalDiagnosticStopAttempted = YES'),
                        request.index('[self.sceneController cvlpRequestNativeSignalDiagnostic:signal]'))
        self.assertNotIn('kill(', request)

    def test_scene_fence_remains_distinct_from_synthetic_and_terminal_revocation(self):
        native = section(PATCHER, '- (BOOL)cvlpRequestNativeSignalDiagnostic:(int)signal {',
                         '- (void)cvlpRevoke {')
        for guard in ('signal != SIGSTOP && signal != SIGCONT', 'self.cvlpRevoked',
                      '!self.cvlpNativeSignalDiagnosticTargetVerified',
                      '!self.cvlpBeginCompleted', 'self.cvlpObservedPID <= 0',
                      'self.pid != self.cvlpObservedPID', 'UIApplicationStateActive',
                      '!self.identifier', '!self.presenter', '!self.view.window',
                      'respondsToSelector:@selector(_kill:)'):
            self.assertIn(guard, native)
        self.assertNotIn('cvlpSyntheticTargetVerified', native)
        self.assertEqual(native.count('[self.extension _kill:signal]'), 1)
        self.assertIn('unproved', native)
        revoke = section(PATCHER, '- (void)cvlpRevoke {', '- (void)setUpAppPresenter {')
        self.assertLess(revoke.index('self.cvlpRevoked = YES'), revoke.index('_kill:SIGKILL'))
        self.assertNotIn('SIGCONT', revoke)

    def test_bridge_never_adopts_verified_pause_capability(self):
        self.assertIn('IntegrationRuntime: NativeGuestSignalDiagnosticRuntime', APP)
        self.assertNotIn('IntegrationRuntime: NativeGuestVerificationRuntime', APP)
        self.assertIn('session.isNativeSignalDiagnosticAvailable', APP)
        self.assertIn('session.requestNativeSignalDiagnostic(SIGSTOP)', APP)
        self.assertIn('session.requestNativeSignalDiagnostic(SIGCONT)', APP)
        self.assertNotIn('suspendForVerification', APP)
        self.assertNotIn('resumeAfterVerification', APP)
        self.assertIn('suspension/media stop/resumption unproved', SESSION)


if __name__ == '__main__':
    unittest.main()
