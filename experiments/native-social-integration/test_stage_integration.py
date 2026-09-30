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
        self.write(self.host / 'CVLPFrameworkGuest.plist', {'bundleIdentifier': 'org.example.syntheticnativeguest.app'})
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

    def test_rejects_real_guest_before_embedding(self):
        self.write(self.host / 'CVLPFrameworkGuest.plist', {'bundleIdentifier': 'unapproved.guest'})
        with self.assertRaisesRegex(ValueError, 'synthetic_guest_required'):
            stage.stage(self.host, self.kit)
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
