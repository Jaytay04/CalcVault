"""Inventory integrity checks; no target code execution or runtime claims."""
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

INDEX = Path(__file__).resolve().parents[1] / 'research' / 'TTKILLERPLUS_2_2_STATIC_INDEX.json'

class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.index = json.loads(INDEX.read_text(encoding='utf-8'))

    def test_complete_declared_method_accounting(self):
        components = self.index['components']
        self.assertEqual(len(components), 19)
        self.assertEqual(sum(c['declaredMethodCount'] for c in components), 578)
        for component in components:
            self.assertEqual(component['declaredMethodCount'], len(component['methods']))
            pairs = [(m['kind'], m['selector']) for m in component['methods']]
            self.assertEqual(len(pairs), len(set(pairs)))
            for method in component['methods']:
                self.assertIn(method['kind'], ('-', '+'))
                self.assertGreater(method['functionBytes'], 0)
                self.assertTrue(method['types'])
                self.assertTrue(all(n > 0 for n in method['directSelectorCalls'].values()))

    def test_target_identity_and_stub_accounting(self):
        self.assertEqual(self.index['counts']['classes'], 18)
        self.assertEqual(self.index['counts']['categories'], 1)
        self.assertEqual(self.index['counts']['functionsWithDirectSelectorCalls'], 976)
        self.assertEqual(self.index['target']['dylibSHA256'],
                         'e99888d3d7e2c37839f5361ccfe2abafcfb1c20ef72c82d9062beb4ed1ab6a55')
        self.assertEqual(self.index['counts']['functionStarts'], 1732)
        self.assertEqual(len(self.index['selectorStubNames']), 978)
        self.assertEqual(len(self.index['preferenceNames']), 23)
        self.assertEqual(self.index['counts']['directSelectorCallSites'], 8061)

    def test_registration_accounting(self):
        hooks = self.index['methodRegistrationCandidates']
        self.assertEqual(self.index['counts']['methodRegistrationSites'], 238)
        self.assertEqual(self.index['counts']['hookFunctionCallSites'], 5)
        self.assertEqual(len(hooks), 238)
        self.assertEqual(sum(h['operation'] == 'hook' for h in hooks), 165)
        self.assertEqual(sum(h['operation'] == 'add' for h in hooks), 73)
        self.assertTrue(all(h['owner'] and h['selector'] for h in hooks))

    def test_all_boolean_toggle_call_sets(self):
        root = next(c for c in self.index['components'] if c['owner'] == 'RootOptionsController')
        toggles = [m for m in root['methods'] if m['selector'].startswith('toggle')]
        required = {'isOn', 'standardUserDefaults', 'setBool:forKey:', 'synchronize'}
        self.assertEqual(len(toggles), 21)
        self.assertTrue(all(required.issubset(m['directSelectorCalls']) for m in toggles))

    def test_cli_rejects_unpinned_fixture_even_with_optimization(self):
        script = Path(__file__).with_name('inventory.py')
        with tempfile.TemporaryDirectory(prefix='ttk-static-fixture-') as directory:
            fixture = Path(directory) / 'synthetic.ipa'
            with zipfile.ZipFile(fixture, 'w') as archive:
                archive.writestr('Payload/Synthetic.app/Frameworks/TTKPlus.dylib', b'synthetic only')
            for flags in ([], ['-O']):
                result = subprocess.run([sys.executable, *flags, str(script), str(fixture)],
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Static inventory rejected', result.stderr)
                self.assertFalse(result.stdout)

    def test_metadata_export_has_no_endpoint_or_resource_payload(self):
        serialized = json.dumps(self.index)
        self.assertNotIn('https://', serialized)
        self.assertNotIn('http://', serialized)
        self.assertNotIn('BEGIN PRIVATE KEY', serialized)
        self.assertNotIn('replacement', serialized)

if __name__ == '__main__':
    unittest.main()
