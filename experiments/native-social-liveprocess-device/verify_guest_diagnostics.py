"""Verify the dedicated synthetic simulator deadline run, without logging content."""

import argparse
from pathlib import Path
import re


LINE = re.compile(r'\bLiveProcess\[(\d+):[^\]]+\].*?CVLP_GUEST_GEOMETRY (phase=\S+.*)$')


def verify(lines):
    records = []
    pids = set()
    for line in lines:
        match = LINE.search(line)
        if match:
            pids.add(match.group(1))
            records.append(dict(re.findall(r'\b([A-Za-z]+)=([^\s]+)', match.group(2))))
    if len(pids) != 1 or not 3 <= len(records) <= 16:
        raise ValueError('diagnostic_process_or_event_bound')
    phases = [record.get('phase') for record in records]
    required = {'armed', 'installed', 'snapshot-1s', 'snapshot-3s', 'snapshot-10s',
                'runloop-2s', 'runloop-8s', 'stopped'}
    if not required <= set(phases) or phases[0] != 'armed' or phases[-1] != 'stopped':
        raise ValueError('missing_scheduler_or_terminal_evidence')
    if phases.count('stopped') != 1 or phases.count('armed') != 1 or phases.count('installed') != 1:
        raise ValueError('duplicate_terminal_or_start')
    try:
        sequence = [int(record['sequence']) for record in records]
        elapsed = [int(record['elapsedMs']) for record in records]
        terminal = records[-1]
        dispatch_count = int(terminal['dispatchSamples'])
        runloop_count = int(terminal['runLoopSamples'])
        notification_count = int(terminal['notificationSamples'])
    except (KeyError, ValueError):
        raise ValueError('missing_or_invalid_numeric_diagnostic') from None
    if sequence != list(range(1, len(records) + 1)) or elapsed != sorted(elapsed) or elapsed[0] < 0:
        raise ValueError('non_monotonic_diagnostic')
    if terminal.get('reason') != 'deadline' or elapsed[-1] < 30000:
        raise ValueError('deadline_not_observed')
    if dispatch_count != sum(phase.startswith('snapshot-') for phase in phases):
        raise ValueError('dispatch_count_mismatch')
    if runloop_count != sum(phase.startswith('runloop-') for phase in phases):
        raise ValueError('runloop_count_mismatch')
    notifications = {'did-finish-launching', 'scene-active', 'window-visible', 'window-key'}
    if notification_count != sum(phase in notifications for phase in phases) or notification_count > 6:
        raise ValueError('notification_count_mismatch')
    return len(records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    args = parser.parse_args()
    try:
        count = verify(args.log.read_text(encoding='utf-8').splitlines())
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
    print(f'PASS: one synthetic guest, {count} bounded observations, both schedulers and terminal deadline')


if __name__ == '__main__':
    main()
