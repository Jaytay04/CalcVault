"""Source contracts for immutable public source mirror retrieval."""
from pathlib import Path
import unittest


class PinnedUpstreamFetchTests(unittest.TestCase):
    def test_all_source_commits_remain_exact_and_mirror_is_not_latest(self):
        source = Path(__file__).with_name('fetch-pinned-upstream.sh').read_text()
        for pin in ('e370a92dfc03ce109ebce00ed4a7cfc64ad1c801',
                    '623c84da314e85363236507ca38a4bde65df21c3',
                    '8025e0c8ebdf5cdd1d2a4f45025813234bf9dc55'):
            self.assertIn(pin, source)
        self.assertEqual(source.count('fetch --depth 1 origin "$pin"'), 2)
        self.assertIn('rev-parse HEAD)" = "$pin"', source)
        self.assertIn('test ! -e "$source/.git"', source)
        self.assertIn('set -euo pipefail', source)
        self.assertNotIn('git pull', source)
        self.assertNotIn('git reset', source)
        self.assertNotIn('--branch main', source)

    def test_integration_uses_shared_exact_pin_fetch_before_preparation(self):
        workflow = Path(__file__).parents[2] / '.github/workflows/native-social-integration.yml'
        source = workflow.read_text()
        self.assertLess(source.index('fetch-pinned-upstream.sh'),
                        source.index('python3 experiments/native-social-liveprocess-device/prepare-upstream.py'))


if __name__ == '__main__':
    unittest.main()
