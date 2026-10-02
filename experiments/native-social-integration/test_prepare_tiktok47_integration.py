import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'prepare_tiktok47_integration', Path(__file__).with_name('prepare-tiktok47-integration.py'))
prepare24 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare24)


class PrepareBuild24Tests(unittest.TestCase):
    def fixture(self):
        sources = {
            prepare24.APP: 'Prepared integration app',
            prepare24.BOOT: 'integration-native-23 ' * 4,
            prepare24.PROBE: prepare24.OBSERVATION + '\n' + prepare24.MARKER + '\n'
                             + 'integration-native-23',
            prepare24.SESSION: 'integration-native-23',
            prepare24.SCENE: 'integration-native-23 ' * 2,
            prepare24.EXTENSION: 'integration-native-23 ' * 2,
            'Unowned/Unchanged.m': 'keep me',
        }
        return sources

    def test_changes_only_the_build_marker_and_fresh_data_directory(self):
        before = self.fixture()
        snapshot = dict(before)
        after = prepare24.transform(before)
        self.assertEqual(before, snapshot)
        self.assertEqual(after['Unowned/Unchanged.m'], 'keep me')
        self.assertIn('Build marker: integration-24.', after[prepare24.PROBE])
        self.assertIn('Integration 24:', after[prepare24.PROBE])
        self.assertNotIn('integration-native-23', '\n'.join(after.values()))
        self.assertEqual(sum(value.count('integration-native-24') for value in after.values()), 10)

    def test_anchor_drift_fails_before_changing_the_input(self):
        before = self.fixture()
        before[prepare24.PROBE] = before[prepare24.PROBE].replace(prepare24.MARKER, 'changed')
        snapshot = dict(before)
        with self.assertRaisesRegex(ValueError, 'build_marker_anchor_drift'):
            prepare24.transform(before)
        self.assertEqual(before, snapshot)

    def test_data_directory_must_match_all_expected_occurrences(self):
        before = self.fixture()
        before[prepare24.BOOT] = before[prepare24.BOOT].replace('integration-native-23', 'other', 1)
        with self.assertRaisesRegex(ValueError, 'guest_data_path_anchor_drift'):
            prepare24.transform(before)


if __name__ == '__main__':
    unittest.main()
