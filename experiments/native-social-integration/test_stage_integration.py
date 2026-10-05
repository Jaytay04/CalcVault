import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('stage', Path(__file__).with_name('stage-integration.py'))
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class IntegrationStageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.host = root / 'Build/Products/Debug-iphoneos/LiveContainer.app'
        self.kit = root / 'Kit/CalcVaultKit.framework'
        (self.host / 'Frameworks').mkdir(parents=True)
        (self.host / 'PlugIns/LiveProcess.appex').mkdir(parents=True)
        self.kit.mkdir(parents=True)
        self.write(self.host / 'Info.plist', {
            'CFBundleIdentifier': 'com.jaylintaylor.calcvault',
            'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True,
            'UIBackgroundModes': ['audio'], 'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True}})
        self.write(self.host / 'CVLPFrameworkGuest.plist', {
            'schema': 1, 'bundleIdentifier': 'org.example.syntheticnativeguest.app',
            'bundleVersion': '1', 'executable': 'NativeGuest'})
        self.write(self.kit / 'Info.plist', {'CFBundleIdentifier': 'com.jaylintaylor.calcvault.kit'})
        (self.kit / 'CalcVaultKit').write_bytes(b'synthetic fixture, not executable code')

    def write(self, path, value):
        path.write_bytes(plistlib.dumps(value))

    def test_embeds_only_kit_and_marks_synthetic_host(self):
        stage.stage(self.host, self.kit)
        info = plistlib.loads((self.host / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleVersion'], '23')
        self.assertEqual(info['CVNativeIntegrationStage'], 'synthetic-integration-23')
        self.assertEqual(info['CVNativeGuestKind'], 'synthetic')
        self.assertFalse(info['UIFileSharingEnabled'])
        self.assertFalse(info['LSSupportsOpeningDocumentsInPlace'])
        self.assertNotIn('NSAppTransportSecurity', info)
        self.assertNotIn('UIBackgroundModes', info)
        self.assertEqual((self.host / 'Frameworks/CalcVaultKit.framework/CalcVaultKit').read_bytes(),
                         (self.kit / 'CalcVaultKit').read_bytes())
        with self.assertRaisesRegex(ValueError, 'kit_already_embedded'):
            stage.stage(self.host, self.kit)

    def test_build24_synthetic_host_is_opt_in_and_keeps_build23_default(self):
        stage.stage(self.host, self.kit, build=24, profile='synthetic')
        info = plistlib.loads((self.host / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleVersion'], '24')
        self.assertEqual(info['CVNativeIntegrationStage'], 'synthetic-integration-24')
        self.assertEqual(info['CVNativeGuestKind'], 'synthetic')

    def test_build24_tiktok47_requires_the_exact_guest_contract(self):
        self.write(self.host / 'CVLPFrameworkGuest.plist', {
            'schema': 1, 'bundleIdentifier': 'com.zhiliaoapp.musically',
            'bundleVersion': '470044', 'executable': 'NativeGuest'})
        stage.stage(self.host, self.kit, build=24, profile='tiktok47')
        info = plistlib.loads((self.host / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleVersion'], '24')
        self.assertEqual(info['CVNativeIntegrationStage'], 'private-tiktok47-integration-24')
        self.assertEqual(info['CVNativeGuestKind'], 'tiktok47')

    def test_build24_rejects_cross_profile_and_unapproved_builds(self):
        with self.assertRaisesRegex(ValueError, 'guest_profile_mismatch'):
            stage.stage(self.host, self.kit, build=24, profile='tiktok47')
        with self.assertRaisesRegex(ValueError, 'unsupported_integration_build'):
            stage.stage(self.host, self.kit, build=25)
        with self.assertRaisesRegex(ValueError, 'unsupported_integration_build'):
            stage.stage(self.host, self.kit, build=True)

    def test_build24_rejects_noninteger_schema_and_extra_contract_fields(self):
        for schema in (True, 1.5):
            self.write(self.host / 'CVLPFrameworkGuest.plist', {
                'schema': schema, 'bundleIdentifier': 'org.example.syntheticnativeguest.app',
                'bundleVersion': '1', 'executable': 'NativeGuest'})
            with self.assertRaisesRegex(ValueError, 'guest_profile_mismatch'):
                stage.stage(self.host, self.kit, build=24, profile='synthetic')
        self.write(self.host / 'CVLPFrameworkGuest.plist', {
            'schema': 1, 'bundleIdentifier': 'org.example.syntheticnativeguest.app',
            'bundleVersion': '1', 'executable': 'NativeGuest', 'extra': 'rejected'})
        with self.assertRaisesRegex(ValueError, 'guest_profile_mismatch'):
            stage.stage(self.host, self.kit, build=24, profile='synthetic')

    def test_rejects_real_guest_before_embedding(self):
        self.write(self.host / 'CVLPFrameworkGuest.plist', {
            'schema': 1, 'bundleIdentifier': 'unapproved.guest',
            'bundleVersion': '1', 'executable': 'NativeGuest'})
        with self.assertRaisesRegex(ValueError, 'synthetic_guest_required'):
            stage.stage(self.host, self.kit)
        self.assertFalse((self.host / 'Frameworks/CalcVaultKit.framework').exists())

    def test_native_pause_flag_is_default_off(self):
        stage.stage(self.host, self.kit, build=24)
        info = plistlib.loads((self.host / 'Info.plist').read_bytes())
        self.assertNotIn('CVNativeSignalDiagnosticEnabled', info)

    def test_native_pause_opt_in_keeps_ci_guest_synthetic(self):
        stage.stage(self.host, self.kit, build=24, signal_diagnostic=True)
        info = plistlib.loads((self.host / 'Info.plist').read_bytes())
        self.assertIs(info['CVNativeSignalDiagnosticEnabled'], True)
        self.assertEqual(info['CVNativeGuestKind'], 'synthetic')

    def test_native_pause_rejects_wrong_build_and_untyped_flag_before_write(self):
        for build, flag in ((23, True), (24, 1), (24, 'true')):
            before = (self.host / 'Info.plist').read_bytes()
            with self.assertRaisesRegex(ValueError, 'unsupported_signal_diagnostic'):
                stage.stage(self.host, self.kit, build=build, signal_diagnostic=flag)
            self.assertEqual((self.host / 'Info.plist').read_bytes(), before)
            self.assertFalse((self.host / 'Frameworks/CalcVaultKit.framework').exists())

    def test_rejects_extra_extensions(self):
        (self.host / 'PlugIns/Extra.appex').mkdir()
        with self.assertRaisesRegex(ValueError, 'unexpected_extension_inventory'):
            stage.stage(self.host, self.kit)

    def test_rejects_unexpected_kit_identity(self):
        self.write(self.kit / 'Info.plist', {'CFBundleIdentifier': 'unapproved.kit'})
        with self.assertRaisesRegex(ValueError, 'unexpected_kit_identity'):
            stage.stage(self.host, self.kit)


if __name__ == '__main__':
    unittest.main()
