"""Synthetic log checks for the simulator diagnostic gate."""

import unittest
from verify_guest_diagnostics import verify


def fixture():
    phases = ['armed', 'installed', 'did-finish-launching', 'snapshot-1s', 'runloop-2s',
              'snapshot-3s', 'runloop-8s', 'snapshot-10s', 'runloop-30s', 'stopped']
    lines = []
    for index, phase in enumerate(phases, 1):
        elapsed = 30000 if index >= 9 else index * 100
        line = f'time Df LiveProcess[123:abc] (Synthetic) CVLP_GUEST_GEOMETRY phase={phase} sequence={index} elapsedMs={elapsed}'
        if phase == 'stopped':
            line += ' reason=deadline dispatchSamples=3 runLoopSamples=3 notificationSamples=1'
        lines.append(line)
    return lines


class DiagnosticLogTests(unittest.TestCase):
    def test_both_schedulers_and_terminal(self):
        self.assertEqual(verify(fixture()), 10)

    def test_missing_path_or_terminal_rejected(self):
        for phase in ('snapshot-1s', 'runloop-2s', 'stopped'):
            with self.subTest(phase=phase), self.assertRaises(ValueError):
                verify([line for line in fixture() if f'phase={phase} ' not in line])

    def test_late_sample_second_process_and_duplicate_stop_rejected(self):
        for tail in (fixture()[3], fixture()[-1], fixture()[3].replace('[123:', '[456:')):
            with self.assertRaises(ValueError):
                verify(fixture() + [tail])

    def test_wrong_counts_time_reason_sequence_rejected(self):
        for original, replacement in (
            ('dispatchSamples=3', 'dispatchSamples=4'),
            ('runLoopSamples=3', 'runLoopSamples=0'),
            ('notificationSamples=1', 'notificationSamples=7'),
            ('reason=deadline', 'reason=app-inactive'),
            ('elapsedMs=30000', 'elapsedMs=50'),
            ('sequence=5', 'sequence=99'),
        ):
            with self.subTest(field=original), self.assertRaises(ValueError):
                verify([line.replace(original, replacement) for line in fixture()])


if __name__ == '__main__':
    unittest.main()
