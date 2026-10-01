"""Opt-in Highlights observations in an already prepared integration source tree.

No guest payload, grants, entitlements, credential gate or lifecycle is changed.
This adapter is not used by ordinary builds.
"""
import argparse
from pathlib import Path
import subprocess

PIN = 'e370a92dfc03ce109ebce00ed4a7cfc64ad1c801'
PROBE = 'LiveContainer/CVLPProbe.m'
HEADER = 'LiveContainer/CVLPHighlightsDiagnostics.h'


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('highlights_anchor_drift')
    return text.replace(old, new, 1)


def transform(probe):
    if 'CVLPHighlightsDiagnostics' in probe:
        raise ValueError('highlights_already_applied')
    probe = once(probe, '#import "CVLPGuestDiagnostics.h"',
                 '#import "CVLPGuestDiagnostics.h"\n#import "CVLPHighlightsDiagnostics.h"')
    probe = once(probe, '    [CVLPGuestGeometryDiagnostics start];',
                 '    [CVLPGuestGeometryDiagnostics start];\n    [CVLPHighlightsDiagnostics start];')
    probe = once(probe, 'if (!CVLPGuestDiagnosticsLineIsSanitized(line)) { return; }',
                 'if (!CVLPGuestDiagnosticsLineIsSanitized(line) &&\n'
                 '        !CVLPHighlightsLineIsSanitized(line)) { return; }')
    return once(probe, 'Build marker: integration-23.',
                'Build marker: integration-23-highlights2.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    if subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip() != PIN:
        raise SystemExit('upstream_revision_mismatch')
    if (root / HEADER).exists():
        raise SystemExit('highlights_already_present')
    updated = transform((root / PROBE).read_text(encoding='utf-8'))
    header = (Path(__file__).parents[1] / 'native-social-liveprocess-device' /
              'CVLPHighlightsDiagnostics.h').read_text(encoding='utf-8')
    (root / PROBE).write_text(updated, encoding='utf-8')
    (root / HEADER).write_text(header, encoding='utf-8')
    print('Opt-in content-free Highlights observations prepared; device results pending')


if __name__ == '__main__':
    main()
