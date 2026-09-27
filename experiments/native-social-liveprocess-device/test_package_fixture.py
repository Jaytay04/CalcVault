"""Tests for the synthetic LiveProcess packaging fixture."""

import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("package-fixture.py")
APP_ID = "com.jaylintaylor.calcvault"
APP_GROUP = "group.com.jaylintaylor.calcvault.nativeprobe"
PHONE_PREFIX = "FAKETEAMID."


def write_plist(path, value):
    path.write_bytes(plistlib.dumps(value))


class PackageFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.host = self.root / "Build" / "Products" / "Debug-iphoneos" / "LiveContainer.app"
        self.plugins = self.host / "PlugIns"
        self.plugins.mkdir(parents=True)
        (self.plugins / "LiveProcess.appex").mkdir()
        (self.plugins / "ShareExtension.appex").mkdir()
        (self.plugins / "LaunchAppExtension.appex").mkdir()

        write_plist(self.host / "Info.plist", {"CFBundleIdentifier": APP_ID})

        self.guest = self.root / "Guest"
        self.guest.mkdir()
        self.guest_info = {
            "CFBundleIdentifier": "org.example.synthetic-guest",
            "CFBundleName": "Synthetic Guest",
            "CFBundleVersion": "3",
        }
        write_plist(self.guest / "Info.plist", self.guest_info)

        self.payload = self.root / "synthetic-payload.dylib"
        self.payload_bytes = b"synthetic payload\x00\x01\xff"
        self.payload.write_bytes(self.payload_bytes)
        self.output = self.root / "entitlements"

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_package(self, simulator=False):
        command = [
            sys.executable,
            str(SCRIPT),
            str(self.host),
            str(self.guest),
            str(self.payload),
            str(self.output),
        ]
        if simulator:
            command.append("--simulator")
        return subprocess.run(command, capture_output=True, text=True, check=False)

    def test_removes_generated_extensions_and_keeps_only_liveprocess(self):
        result = self.run_package()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([path.name for path in self.plugins.iterdir()], ["LiveProcess.appex"])
        self.assertFalse((self.plugins / "ShareExtension.appex").exists())
        self.assertFalse((self.plugins / "LaunchAppExtension.appex").exists())

    def test_resource_bundle_contains_guest_info_metadata(self):
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stderr)

        resources = self.host / "SyntheticGuestResources.bundle"
        resource_info = plistlib.loads((resources / "Info.plist").read_bytes())
        copied_guest_info = plistlib.loads((resources / "GuestInfo.plist").read_bytes())

        self.assertEqual(resource_info["CFBundlePackageType"], "BNDL")
        self.assertEqual(resource_info["CFBundleIdentifier"], "org.example.cvlp.resources")
        self.assertEqual(resource_info["CFBundleVersion"], "19")
        host_info = plistlib.loads((self.host / "Info.plist").read_bytes())
        self.assertEqual(host_info["CFBundleVersion"], "19")
        self.assertIn("synthetic", host_info["NSFaceIDUsageDescription"])
        self.assertEqual(copied_guest_info, self.guest_info)

    def test_embedded_payload_is_preserved_byte_for_byte(self):
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stderr)

        embedded_payload = self.host / "Frameworks" / "SyntheticNativeGuestPayload.dylib"
        self.assertEqual(embedded_payload.read_bytes(), self.payload_bytes)

    def test_phone_extension_excludes_host_only_keychain_group(self):
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stderr)

        host_entitlements = plistlib.loads((self.output / "host.entitlements").read_bytes())
        extension_entitlements = plistlib.loads((self.output / "extension.entitlements").read_bytes())
        host_only_group = PHONE_PREFIX + APP_ID + ".hostonly"

        self.assertIn(host_only_group, host_entitlements["keychain-access-groups"])
        self.assertEqual(
            extension_entitlements["keychain-access-groups"],
            [PHONE_PREFIX + APP_ID, PHONE_PREFIX + "com.kdt.livecontainer.shared"],
        )
        self.assertNotIn(host_only_group, extension_entitlements["keychain-access-groups"])
        self.assertEqual(extension_entitlements["com.apple.security.application-groups"], [APP_GROUP])

    def test_simulator_entitlements_contain_only_app_group(self):
        result = self.run_package(simulator=True)
        self.assertEqual(result.returncode, 0, result.stderr)

        expected = {"com.apple.security.application-groups": [APP_GROUP]}
        for name in ("host", "extension"):
            with self.subTest(entitlement_file=name):
                entitlements = plistlib.loads((self.output / f"{name}.entitlements").read_bytes())
                self.assertEqual(entitlements, expected)
                self.assertNotIn("keychain-access-groups", entitlements)
                self.assertNotIn("get-task-allow", entitlements)

    def test_refuses_an_unreviewed_extension(self):
        (self.plugins / "Unexpected.appex").mkdir()

        result = self.run_package()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected only the reviewed LiveProcess extension", result.stderr)

    def test_refuses_a_nested_app(self):
        (self.plugins / "LiveProcess.appex" / "Nested.app").mkdir()

        result = self.run_package()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("A guest must not be packaged as another app product", result.stderr)


if __name__ == "__main__":
    unittest.main()
