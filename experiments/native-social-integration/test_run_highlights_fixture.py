import importlib.util
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock


SPEC = importlib.util.spec_from_file_location('bounded_highlights_fixture',
    Path(__file__).with_name('run-highlights-fixture.py'))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BoundedFixtureLaunchTests(unittest.TestCase):
    def test_success_requires_zero_launch_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            runner = Mock(return_value=SimpleNamespace(returncode=0))
            self.assertEqual(MODULE.run('synthetic-simulator', Path(folder) / 'console', runner), 0)
            self.assertEqual(runner.call_count, 1)
            self.assertEqual(runner.call_args.kwargs['timeout'], 180)
            self.assertEqual(runner.call_args.args[0][-1], MODULE.FIXTURE_ID)

    def test_nonzero_launch_is_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            runner = Mock(return_value=SimpleNamespace(returncode=1))
            self.assertEqual(MODULE.run('synthetic-simulator', Path(folder) / 'console', runner), 1)
            self.assertEqual(runner.call_count, 1)

    def test_timeout_terminates_only_fixture_and_preserves_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            console = Path(folder) / 'console'
            runner = Mock(side_effect=[subprocess.TimeoutExpired('synthetic-launch', 180),
                                       SimpleNamespace(returncode=0)])
            self.assertEqual(MODULE.run('synthetic-simulator', console, runner), 1)
            self.assertEqual(runner.call_count, 2)
            terminate = runner.call_args_list[1]
            self.assertEqual(terminate.args[0], ['xcrun', 'simctl', 'terminate',
                                               'synthetic-simulator', MODULE.FIXTURE_ID])
            self.assertEqual(terminate.kwargs['timeout'], 15)
            self.assertIn('LAUNCH_TIMEOUT', console.read_text())

    def test_termination_timeout_cannot_turn_failure_into_success(self):
        with tempfile.TemporaryDirectory() as folder:
            console = Path(folder) / 'console'
            runner = Mock(side_effect=[subprocess.TimeoutExpired('synthetic-launch', 180),
                                       subprocess.TimeoutExpired('synthetic-terminate', 15)])
            self.assertEqual(MODULE.run('synthetic-simulator', console, runner), 1)
            self.assertIn('TERMINATION_UNPROVED', console.read_text())


if __name__ == '__main__':
    unittest.main()
