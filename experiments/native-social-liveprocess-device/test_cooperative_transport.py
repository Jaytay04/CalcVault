"""Adapter/source contracts only: no claim of executed XPC or media silence."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location('cooperative_adapter', ROOT / 'prepare-cooperative-pause.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
CONTROL = (ROOT / 'CVLPCooperativePause.m').read_text(encoding='utf-8')
HEADER = (ROOT / 'CVLPCooperativePause.h').read_text(encoding='utf-8')
SESSION = (ROOT / 'CVLPGuestSession.m').read_text(encoding='utf-8')


class CooperativeTransportTests(unittest.TestCase):
    def fixture(self):
        return ('integration-native-24\n#import "../LiveContainer/CVLPLiveness.h"\n'
                '@property(nonatomic) BOOL cvlpNativeSignalDiagnosticTargetVerified;\n'
                '    item.userInfo = userInfo;\n- (void)cvlpRevoke {\n'
                '- (void)appTerminationCleanUp {',
                'integration-native-24\n#import "../LiveContainer/CVLPProbe.h"\n'
                '    NSCAssert(appInfo, @"Failed to retrieve app info");\n'
                '    NSLog(@"CVLP_DEVICE_EXTENSION_STARTED");')

    def test_opt_in_preserves_lifecycle_and_namespace(self):
        scene, guest = adapter.transform(*self.fixture())
        self.assertIn('CVNativeCooperativePauseEnabled', scene)
        self.assertIn('CFBooleanGetTypeID()', scene)
        self.assertIn('private-tiktok47-integration-24', scene)
        self.assertIn('CVNativeSignalDiagnosticEnabled', scene)
        self.assertIn('[owner appTerminationCleanUp]', scene)
        self.assertIn('[self.cvlpMediaControl invalidate]', scene)
        self.assertIn('CVLPInstallGuestMediaHoldControl(appInfo)', guest)
        self.assertNotIn('NSLog(@"Retrieved app info: %@", appInfo)', guest)
        self.assertIn('values redacted', guest)
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

    def test_startup_sends_a_message_and_never_grants_host_storage_authority(self):
        connector = CONTROL.split('NSXPCConnection *CVLPCreateGuestMediaHoldConnection(')[1].split(
            '#if defined(CVLP_COOPERATIVE_GUEST)')[0]
        self.assertIn('@protocol(CVLPGuestMediaHoldBootstrap)', connector)
        self.assertLess(connector.index('[connection resume]'), connector.index('[bootstrap announceForLaunch:'))
        self.assertIn('10 * NSEC_PER_SEC', connector)
        self.assertIn('if (startupFinished) return', connector)
        guest = CONTROL.split('#if defined(CVLP_COOPERATIVE_GUEST)')[1].split('#else')[0]
        self.assertIn('CVLPCreateGuestMediaHoldConnection(endpoint, token, control, lostControl', guest)
        protocol = HEADER.split('@protocol CVLPGuestMediaHoldBootstrap')[1].split('@end')[0]
        self.assertEqual(protocol.count('- (void)'), 1)
        self.assertIn('announceForLaunch:(NSUUID *)launch', protocol)
        self.assertNotIn('NSString', protocol)
        self.assertNotIn('NSDictionary', protocol)
        self.assertNotIn('NSData', protocol)
        self.assertNotIn('exportedObject = self', CONTROL)

    def test_registration_is_not_media_authorization_and_is_connection_fenced(self):
        registration = CONTROL.split('- (void)registerLaunch:(NSUUID *)launch connection:')[2].split(
            '- (BOOL)peerIsCurrent:')[0]
        for guard in ('!self.invalidated', 'connection == self.connection',
                      '[launch isEqual:self.launchToken]', '!self.bootstrapReceived', '[self failConnection]'):
            self.assertIn(guard, registration)
        self.assertIn('NSXPCConnection.currentConnection', CONTROL)
        self.assertIn('@property(atomic) BOOL transportLost', CONTROL)
        loss = CONTROL.split('void (^lostControl)(void) = ^{')[-1].split('connection.interruptionHandler')[0]
        self.assertLess(loss.index('weakSelf.transportLost = YES'), loss.index('dispatch_async'))
        peer = CONTROL.split('- (BOOL)peerIsCurrent:')[1].split('- (BOOL)isAvailableForPID:')[0]
        self.assertIn('self.bootstrapReceived', peer)
        self.assertIn('!self.transportLost', peer)
        self.assertIn('self.connection.processIdentifier == pid', peer)
        self.assertIn('CVLPProcessPresenceObserved', peer)
        self.assertNotIn('pauseForPID', registration)
        self.assertNotIn('resumeForPID', registration)

    def test_readiness_diagnostics_are_fixed_content_and_saved_before_cleanup(self):
        for field in ('connection=%d', 'startup=%d', 'peerMatch=%d', 'presence=%d', 'reason=%@'):
            self.assertIn(field, CONTROL)
        self.assertIn('Cooperative startup diagnostic v2', SESSION)
        revoke = SESSION.split('- (void)revoke {')[1].split('- (void)observeExit')[0]
        self.assertLess(revoke.index('[self isCooperativePauseAvailable]'), revoke.index('self.revoked = YES'))
        scene, _ = adapter.transform(*self.fixture())
        self.assertIn('cvlpCooperativePauseReadinessDiagnostic', scene)
        self.assertIn('reason=no-channel', scene)


if __name__ == '__main__':
    unittest.main()
