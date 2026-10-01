"""Bounded simulator launch for the disposable, content-free native fixture."""

import argparse
from pathlib import Path
import subprocess


FIXTURE_ID = 'org.example.synthetic.highlights-observer-tests'


def run(simulator, console, runner=subprocess.run):
    with Path(console).open('w', encoding='utf-8') as stream:
        try:
            result = runner(['xcrun', 'simctl', 'launch', '--terminate-running-process',
                             '--console', simulator, FIXTURE_ID], stdout=stream,
                            stderr=subprocess.STDOUT, timeout=180, check=False)
            return 0 if result.returncode == 0 else 1
        except subprocess.TimeoutExpired:
            stream.write('CV_HIGHLIGHTS_FIXTURE_LAUNCH_TIMEOUT\n')
            stream.flush()
            try:
                runner(['xcrun', 'simctl', 'terminate', simulator, FIXTURE_ID],
                       stdout=stream, stderr=subprocess.STDOUT, timeout=15, check=False)
            except (subprocess.TimeoutExpired, OSError):
                stream.write('CV_HIGHLIGHTS_FIXTURE_TERMINATION_UNPROVED\n')
            return 1
        except OSError:
            stream.write('CV_HIGHLIGHTS_FIXTURE_LAUNCH_UNAVAILABLE\n')
            return 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator')
    parser.add_argument('console', type=Path)
    args = parser.parse_args()
    raise SystemExit(run(args.simulator, args.console))
