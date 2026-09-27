"""Bounded tests for the SideStore entitlement template validator."""

import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts" / "credential-entitlements.py"
TEMPLATE = ROOT / "config" / "host-keychain.entitlements"
EXPECTED = {
    "application-identifier": "FAKETEAMID.com.jaylintaylor.calcvault",
    "keychain-access-groups": [
        "FAKETEAMID.com.jaylintaylor.calcvault",
        "FAKETEAMID.com.jaylintaylor.calcvault.hostonly",
    ],
}


class CredentialEntitlementTests(unittest.TestCase):
    def validate_file(self, value):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "entitlements.plist"
            path.write_bytes(plistlib.dumps(value))
            return subprocess.run(
                [sys.executable, str(VALIDATOR), str(path)],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_source_template_has_exact_values_and_order(self):
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), str(TEMPLATE)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_reordered_keychain_groups(self):
        value = dict(EXPECTED)
        value["keychain-access-groups"] = list(reversed(EXPECTED["keychain-access-groups"]))
        self.assertNotEqual(self.validate_file(value).returncode, 0)

    def test_rejects_extra_debug_or_shared_entitlements(self):
        for key, value_to_add in (
            ("get-task-allow", True),
            ("com.apple.security.application-groups", ["group.example"]),
        ):
            with self.subTest(key=key):
                value = dict(EXPECTED)
                value[key] = value_to_add
                self.assertNotEqual(self.validate_file(value).returncode, 0)

    def test_rejects_malformed_plist_without_traceback(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "entitlements.plist"
            path.write_text("not a plist", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(VALIDATOR), str(path)],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stderr.startswith("error:"))


if __name__ == "__main__":
    unittest.main()
