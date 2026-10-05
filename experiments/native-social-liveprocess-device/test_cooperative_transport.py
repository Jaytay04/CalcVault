"""Adapter/source contracts only: no claim of executed XPC or media silence."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location('cooperative_adapter', ROOT / 'prepare-cooperative-pause.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
CONTROL = (ROOT / 'CVLPCooperativePause.m').read_text(encoding='utf-8')
SESSION = (ROOT / 'CVLPGuestSession.m').read_text(encoding='utf-8')


class CooperativeTransportTests(unittest.TestCase):
    def fixture(self):
        return ('integration-native-24\n#import "../LiveContainer/CVLPLiveness.h"\n'
                '@property(nonatomic) BOOL cvlpNativeSignalDiagnosticTargetVerified;\n'
                '    item.userInfo = userInfo;\n- (void)cvlpRevoke {\n'
                '- (void)appTerminationCleanUp {',
                'integration-native-24\n#import "../LiveContainer/CVLPProbe.h"\n'
                '    NSCAssert(appInfo, @"Failed to retrieve app info");')

    def test_opt_in_preserves_lifecycle_and_namespace(self):
        scene, guest = adapter.transform(*self.fixture())
        self.assertIn('CVNativeCooperativePauseEnabled', scene)
        self.assertIn('CFBooleanGetTypeID()', scene)
        self.assertIn('private-tiktok47-integration-24', scene)
        self.assertIn('CVNativeSignalDiagnosticEnabled', scene)
        self.assertIn('[owner appTerminationCleanUp]', scene)
        self.assertIn('[self.cvlpMediaControl invalidate]', scene)
        self.assertIn('CVLPInstallGuestMediaHoldControl(appInfo)', guest)
        self.assertNotIn('SIGSTOP', scene + guest)
        self.assertNotIn('shouldIgnoreSceneUpdates', scene)
        self.assertNotIn('integration-native-25', scene + guest)

    def test_wrong_build_repeat_and_drift_fail_closed(self):
        scene, guest = self.fixture()
        for invalid in (scene.replace('24', '23'), scene.replace('item.userInfo', 'missing'), scene + scene):
            with self.assertRaises(ValueError):
                adapter.transform(invalid, guest)
        prepared = adapter.transform(scene, guest)
        with self.assertRaises(ValueError):
            adapter.transform(*prepared)

    def test_async_channel_is_peer_token_one_shot_and_timeout_fenced(self):
        for guard in ('NSXPCListener.anonymousListener', '!self.acceptedConnection',
                      'connection.processIdentifier == pid', 'reportedPID == pid',
                      'CVLPProcessPresenceObserved', '[launch isEqual:self.launchToken]',
                      'self.holdToken = NSUUID.UUID', '!self.pauseAttempted',
                      'self.resumeAttempted', 'self.operation != operation',
                      '3 * NSEC_PER_SEC', 'duration:120', '[self failConnection]'):
            self.assertIn(guard, CONTROL)
        self.assertNotIn('exportedObject = self', CONTROL)
        self.assertNotIn('SIGCONT', CONTROL)
        self.assertNotIn('SIGSTOP', CONTROL)
        self.assertIn('if (!endpoint && !token) return YES', CONTROL)
        self.assertIn('_exit(102)', CONTROL)
        self.assertIn('_exit(103)', CONTROL)
        invalidation = CONTROL.split('- (void)invalidate {')[1].split('- (void)dealloc')[0]
        self.assertLess(invalidation.index('self.invalidated = YES'), invalidation.index('if (reply) reply(NO)'))
        self.assertLess(invalidation.index('self.pendingReply = nil'), invalidation.index('if (reply) reply(NO)'))

    def test_exact_identity_and_default_off_selector_guard(self):
        identity = SESSION.split('- (BOOL)cooperativePauseIdentityIsVerified {')[1].split(
            '- (BOOL)cooperativePauseRequestIsReady {')[0]
        for value in ('CVNativeCooperativePauseEnabled', 'CFBooleanGetTypeID()',
                      'CVNativeSignalDiagnosticEnabled', 'integration-native-24',
                      'CVLPFrameworkGuestURL', '470044', '47.0.0', 'NativeGuest'):
            self.assertIn(value, identity)
        self.assertIn('respondsToSelector:@selector(setCvlpCooperativePauseTargetVerified:)', SESSION)
        self.assertIn('BOOL current = applied && [self cooperativePauseRequestIsReady]', SESSION)
        self.assertIn('BOOL current = released && [self cooperativePauseRequestIsReady]', SESSION)
        self.assertIn('Cooperative media diagnostic v1', SESSION)


if __name__ == '__main__':
    unittest.main()
