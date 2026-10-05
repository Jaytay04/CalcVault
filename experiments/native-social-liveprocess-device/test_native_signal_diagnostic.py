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
        for guard in ('!self.revoked', '!self.sceneEnded', 'self.sceneController.cvlpBeginCompleted',
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
                      'self.cvlpSceneEnded',
                      '!self.cvlpNativeSignalDiagnosticTargetVerified',
                      '!self.cvlpBeginCompleted', 'self.cvlpObservedPID <= 0',
                      'self.pid != self.cvlpObservedPID', 'UIApplicationStateActive',
                      '!self.identifier', '!self.presenter', '!self.view.window',
                      'respondsToSelector:@selector(_kill:)'):
            self.assertIn(guard, native)
        self.assertNotIn('cvlpSyntheticTargetVerified', native)
        self.assertEqual(native.count('[self.extension _kill:signal]'), 1)
        self.assertIn('unproved', native)
        self.assertIn('CVLPSampleLiveness((pid_t)self.cvlpObservedPID)', native)
        self.assertIn('CVLPProcessPresenceObserved(bridgeSample)', native)
        self.assertLess(native.index('respondsToSelector:@selector(_kill:)'),
                        native.index('CVLPSampleLiveness((pid_t)self.cvlpObservedPID)'))
        self.assertLess(native.index('CVLPSampleLiveness((pid_t)self.cvlpObservedPID)'),
                        native.index('[self.extension _kill:signal]'))
        revoke = section(PATCHER, '- (void)cvlpRevoke {', '- (void)setUpAppPresenter {')
        self.assertLess(revoke.index('self.cvlpRevoked = YES'), revoke.index('_kill:SIGKILL'))
        self.assertNotIn('SIGCONT', revoke)

    def test_session_terminal_callback_is_independent_and_explicit_revoke_is_expected(self):
        scene_exit = section(SESSION, '- (void)appSceneVCAppDidExit:',
                             '- (void)appSceneVCWillActivateScene:')
        self.assertLess(scene_exit.index('self.sceneEnded = YES'),
                        scene_exit.index('[self deliverUnexpectedTerminationIfReady]'))
        self.assertLess(scene_exit.index('self.launchResult = @"scene ended"'),
                        scene_exit.index('[self deliverUnexpectedTerminationIfReady]'))
        self.assertLess(scene_exit.index('[self deliverUnexpectedTerminationIfReady]'),
                        scene_exit.index('[self deliverCompletion:NO]'))
        self.assertIn('if (!self.revoked)', scene_exit)
        self.assertIn('self.unexpectedSceneExitObserved = YES', scene_exit)
        delivery = section(SESSION, '- (void)deliverUnexpectedTerminationIfReady {',
                           '- (void)recordDiagnosticPhase:')
        for guard in ('!self.unexpectedSceneExitObserved', 'self.terminationCallbackDelivered',
                      '!self.storedTerminationHandler', 'self.terminationCallbackDelivered = YES'):
            self.assertIn(guard, delivery)
        revoke = section(SESSION, '- (void)revoke {', '- (void)observeExit {')
        self.assertIn('reason:@"explicit"', revoke)
        self.assertIn('self.terminationHandler = nil', revoke)
        self.assertNotIn('self.unexpectedSceneExitObserved = YES', revoke)
        self.assertIn('return self.started && !self.revoked && !self.sceneEnded', SESSION)

    def test_session_event_ring_is_bounded_sanitized_and_observers_are_removed(self):
        recorder = section(SESSION,
                           '- (void)recordDiagnosticPhase:(NSString *)phase reason:(NSString *)reason\n'
                           '                       sample:(CVLPLivenessSample)sample hasSample:(BOOL)hasSample {',
                           '- (void)installHostLifecycleObservers {')
        self.assertIn('systemUptime', recorder)
        self.assertIn('diagnosticEvents.count > 48', recorder)
        self.assertIn('removeObjectAtIndex:0', recorder)
        for fixed_value in ('@"STOP"', '@"CONT"', '@"host"', '@"scene"',
                            '@"revoke"', '@"reject"', 'sample=%@', 'pid=%d'):
            self.assertIn(fixed_value, recorder)
        for forbidden in ('localizedDescription', 'UUID', 'cookie', 'credential', 'URL'):
            self.assertNotIn(forbidden, recorder)
        observers = section(SESSION, '- (void)installHostLifecycleObservers {', '- (void)startWithCompletion:')
        for lifecycle in ('UIApplicationWillResignActiveNotification',
                          'UIApplicationDidEnterBackgroundNotification',
                          'UIApplicationDidBecomeActiveNotification', 'NSOperationQueue.mainQueue'):
            self.assertIn(lifecycle, observers)
        self.assertIn('removeObserver:observer', SESSION)
        self.assertIn('[self removeHostLifecycleObservers]', section(
            SESSION, '- (void)revoke {', '- (void)observeExit {'))
        for event in ('@"before"', '@"after-submitted"', '@"after-rejected"',
                      '@"unexpected-exit"', '@"explicit"', '@"inactive"',
                      '@"background"', '@"active"'):
            self.assertIn(event, SESSION)

    def test_preparation_traces_both_interrupt_registrations_and_cleanup_paths(self):
        for trace in ('interruption-initial-registration', 'interruption-initial-callback',
                      'interruption-presenter-registration', 'interruption-presenter-callback',
                      'reason:@"cancellation"', 'reason:@"trigger"',
                      'reason:@"process-not-running"', 'reason:@"pid-unavailable"',
                      'reason:@"missing-process-callback"'):
            self.assertIn(trace, PATCHER)
        self.assertGreaterEqual(PATCHER.count('setRequestInterruptionBlock'), 4)
        self.assertIn('self.cvlpSceneEnded = YES', PATCHER)
        self.assertIn('if (self.cvlpRevoked || self.cvlpSceneEnded) return;', PATCHER)
        self.assertIn('appTerminationCleanUp];', PATCHER)
        # The generated source must preserve an escaped newline in its trace summary.
        self.assertIn('componentsJoinedByString:@"\\\\n"', PATCHER)

    def test_bridge_never_adopts_verified_pause_capability(self):
        self.assertIn('IntegrationRuntime: NativeGuestSignalDiagnosticRuntime', APP)
        self.assertIn('IntegrationRuntime: NativeGuestSignalDiagnosticRuntime, NativeGuestTerminationReportingRuntime', APP)
        self.assertNotIn('IntegrationRuntime: NativeGuestVerificationRuntime', APP)
        self.assertIn('var terminationHandler: (@MainActor () -> Void)?', APP)
        self.assertIn('session.terminationHandler = { [weak self] in', APP)
        self.assertIn('MainActor.assumeIsolated', APP)
        self.assertIn('session.isNativeSignalDiagnosticAvailable', APP)
        self.assertIn('session.requestNativeSignalDiagnostic(SIGSTOP)', APP)
        self.assertIn('session.requestNativeSignalDiagnostic(SIGCONT)', APP)
        self.assertNotIn('suspendForVerification', APP)
        self.assertNotIn('resumeAfterVerification', APP)
        self.assertIn('suspension/media stop/resumption unproved', SESSION)


if __name__ == '__main__':
    unittest.main()
