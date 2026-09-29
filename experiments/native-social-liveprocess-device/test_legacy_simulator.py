"""Safety checks for legacy simulator staging; no native execution or signing."""

import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    'stage_legacy_simulator', Path(__file__).with_name('stage_legacy_simulator.py'))
stage_legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage_legacy)


def simulator_dylib(platform=stage_legacy.PLATFORM_IOS_SIMULATOR,
                    cpu_type=stage_legacy.CPU_TYPE_ARM64, file_type=stage_legacy.MH_DYLIB):
    load_command = struct.pack('<6I', stage_legacy.LC_BUILD_VERSION, 24,
                               platform, 0x00120000, 0x00120000, 0)
    header = struct.pack('<8I', stage_legacy.MACHO_MAGIC_64, cpu_type, 0,
                         file_type, 1, len(load_command), 0, 0)
    return header + load_command


class LegacySimulatorStagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.host = self.root / 'cvlp-legacy-host/Build/Products/Debug-iphonesimulator/LiveContainer.app'
        self.framework = self.host / 'Frameworks/NativeGuest.framework'
        self.framework.mkdir(parents=True)
        self.host_info = {'CFBundleIdentifier': stage_legacy.HOST_ID,
                          'CVLPFrameworkGuestMode': 1, 'CFBundleVersion': '20'}
        (self.host / 'Info.plist').write_bytes(plistlib.dumps(self.host_info))
        self.original_framework_info = {
            'CFBundleIdentifier': stage_legacy.GUEST_ID, 'CFBundleVersion': '19',
            'CFBundleExecutable': 'NativeGuest', 'CFBundlePackageType': 'FMWK'}
        (self.framework / 'Info.plist').write_bytes(plistlib.dumps(self.original_framework_info))
        (self.framework / 'NativeGuest').write_bytes(b'original simulator guest')
        signature = self.framework / '_CodeSignature'
        signature.mkdir()
        (signature / 'CodeResources').write_bytes(b'old signature is replaced by codesign')
        self.descriptor = self.host / 'CVLPFrameworkGuest.plist'
        self.descriptor.write_bytes(plistlib.dumps({
            'schema': 1, 'bundleIdentifier': stage_legacy.GUEST_ID,
            'bundleVersion': '19', 'executable': 'NativeGuest'}))
        self.guest = self.root / 'cvlp-legacy-guest/Build/Products/Release-iphonesimulator/CVLPGuest.app'
        self.guest.mkdir(parents=True)
        self.guest_info = {
            'CFBundleIdentifier': stage_legacy.GUEST_ID, 'CFBundleVersion': '19',
            'CFBundleExecutable': 'CVLPGuest', 'CFBundlePackageType': 'APPL',
            'UIApplicationSceneManifest': {'UISceneConfigurations': {}},
            'LCSyntheticGuestExecutable': 'Frameworks/SyntheticNativeGuestPayload.dylib'}
        (self.guest / 'Info.plist').write_bytes(plistlib.dumps(self.guest_info))
        self.payload = self.root / 'cvlp-legacy-payload.dylib'
        self.payload.write_bytes(simulator_dylib())

    def run_stage(self):
        stage_legacy.stage(self.host, self.guest, self.payload)

    def test_replaces_only_synthetic_framework_and_sanitizes_legacy_manifest(self):
        original_host_info = (self.host / 'Info.plist').read_bytes()
        signature = self.framework / '_CodeSignature/CodeResources'
        self.run_stage()

        guest_info = plistlib.loads((self.guest / 'Info.plist').read_bytes())
        self.assertNotIn('UIApplicationSceneManifest', guest_info)
        self.assertIs(guest_info['UIRequiresFullScreen'], True)
        framework_info = plistlib.loads((self.framework / 'Info.plist').read_bytes())
        self.assertEqual(framework_info['CFBundleIdentifier'], stage_legacy.GUEST_ID)
        self.assertEqual(framework_info['CFBundleExecutable'], 'NativeGuest')
        self.assertEqual(framework_info['CFBundlePackageType'], 'FMWK')
        self.assertNotIn('UIApplicationSceneManifest', framework_info)
        self.assertNotIn('LCSyntheticGuestExecutable', framework_info)
        self.assertIs(framework_info['UIRequiresFullScreen'], True)
        self.assertEqual((self.framework / 'NativeGuest').read_bytes(), self.payload.read_bytes())
        self.assertEqual(plistlib.loads(self.descriptor.read_bytes())['bundleIdentifier'], stage_legacy.GUEST_ID)
        self.assertEqual((self.host / 'Info.plist').read_bytes(), original_host_info)
        self.assertEqual(signature.read_bytes(), b'old signature is replaced by codesign')

    def test_rejects_device_payload_before_mutating_any_input(self):
        self.payload.write_bytes(simulator_dylib(platform=2))
        guest_before = (self.guest / 'Info.plist').read_bytes()
        framework_before = (self.framework / 'Info.plist').read_bytes()
        with self.assertRaisesRegex(ValueError, 'expected_ios_simulator_build'):
            self.run_stage()
        self.assertEqual((self.guest / 'Info.plist').read_bytes(), guest_before)
        self.assertEqual((self.framework / 'Info.plist').read_bytes(), framework_before)

    def test_rejects_host_outside_dedicated_simulator_clone(self):
        wrong_host = self.root / 'Build/Products/Debug-iphonesimulator/LiveContainer.app'
        wrong_host.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, 'expected_isolated_simulator_host_clone'):
            stage_legacy.stage(wrong_host, self.guest, self.payload)

    def test_rejects_non_synthetic_framework(self):
        changed = dict(self.original_framework_info, CFBundleIdentifier='com.zhiliaoapp.musically')
        (self.framework / 'Info.plist').write_bytes(plistlib.dumps(changed))
        guest_before = (self.guest / 'Info.plist').read_bytes()
        with self.assertRaisesRegex(ValueError, 'synthetic_framework_only'):
            self.run_stage()
        self.assertEqual((self.guest / 'Info.plist').read_bytes(), guest_before)


if __name__ == '__main__':
    unittest.main()
