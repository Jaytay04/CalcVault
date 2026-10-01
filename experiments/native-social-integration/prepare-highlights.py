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


def transform(probe, viewing_experiment=False, direct_viewing_experiment=False,
              early_viewing_experiment=False):
    if sum((viewing_experiment, direct_viewing_experiment, early_viewing_experiment)) > 1:
        raise ValueError('highlights_experiments_mutually_exclusive')
    if 'CVLPHighlightsDiagnostics' in probe:
        raise ValueError('highlights_already_applied')
    configuration = '#define CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT 1\n' if viewing_experiment else ''
    if direct_viewing_experiment:
        configuration = '#define CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT 1\n'
    if early_viewing_experiment:
        configuration = '#define CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT 1\n'
    probe = once(probe, '#import "CVLPGuestDiagnostics.h"',
                 '#import "CVLPGuestDiagnostics.h"\n' + configuration + '#import "CVLPHighlightsDiagnostics.h"')
    probe = once(probe, '    [CVLPGuestGeometryDiagnostics start];',
                 '    [CVLPGuestGeometryDiagnostics start];\n    [CVLPHighlightsDiagnostics start];')
    if early_viewing_experiment:
        probe = once(probe, '+ (void)startGuestGeometryObservations {',
                     '+ (void)armEarlyHighlightsViewing {\n'
                     '    [CVLPHighlightsDiagnostics armEarlyViewing];\n}\n\n'
                     '+ (void)finishEarlyHighlightsViewingLoad {\n'
                     '    [CVLPHighlightsDiagnostics finishEarlyViewingLoad];\n}\n\n'
                     '+ (void)startGuestGeometryObservations {')
    probe = once(probe, 'if (!CVLPGuestDiagnosticsLineIsSanitized(line)) { return; }',
                 'if (!CVLPGuestDiagnosticsLineIsSanitized(line) &&\n'
                 '        !CVLPHighlightsLineIsSanitized(line)) { return; }')
    marker = 'integration-23-highlights-viewing1' if viewing_experiment else 'integration-23-highlights2'
    if direct_viewing_experiment:
        marker = 'integration-23-highlights-directviewing1'
    if early_viewing_experiment:
        marker = 'integration-23-highlights-earlyviewing1'
    return once(probe, 'Build marker: integration-23.', f'Build marker: {marker}.')


def transform_early_bootstrap(bootstrap, probe_header):
    """Arm only within the already approved guest load; always finish after return."""
    bootstrap = once(bootstrap,
        '        appHandle = dlopen_nolock(appExecPath, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);',
        '        [CVLPProbe armEarlyHighlightsViewing];\n'
        '        @try {\n'
        '            appHandle = dlopen_nolock(appExecPath, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);\n'
        '        } @finally {\n'
        '            [CVLPProbe finishEarlyHighlightsViewingLoad];\n'
        '        }')
    probe_header = once(probe_header, '@end',
        '+ (void)armEarlyHighlightsViewing;\n'
        '+ (void)finishEarlyHighlightsViewingLoad;\n\n@end')
    return bootstrap, probe_header


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--viewing-experiment', action='store_true',
                        help='Explicit temporary consumption-only true-return experiment')
    parser.add_argument('--direct-viewing-experiment', action='store_true',
                        help='Explicit pinned native consumption-pointer experiment')
    parser.add_argument('--early-viewing-experiment', action='store_true',
                        help='Explicit pre-initializer pinned native consumption-pointer experiment')
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    if subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip() != PIN:
        raise SystemExit('upstream_revision_mismatch')
    if (root / HEADER).exists():
        raise SystemExit('highlights_already_present')
    updated = transform((root / PROBE).read_text(encoding='utf-8'), args.viewing_experiment,
                        args.direct_viewing_experiment, args.early_viewing_experiment)
    if args.early_viewing_experiment:
        bootstrap_path = root / 'LiveContainer/LCBootstrap.m'
        probe_header_path = root / 'LiveContainer/CVLPProbe.h'
        bootstrap, probe_header = transform_early_bootstrap(
            bootstrap_path.read_text(encoding='utf-8'),
            probe_header_path.read_text(encoding='utf-8'))
    header = (Path(__file__).parents[1] / 'native-social-liveprocess-device' /
              'CVLPHighlightsDiagnostics.h').read_text(encoding='utf-8')
    (root / PROBE).write_text(updated, encoding='utf-8')
    (root / HEADER).write_text(header, encoding='utf-8')
    if args.early_viewing_experiment:
        bootstrap_path.write_text(bootstrap, encoding='utf-8')
        probe_header_path.write_text(probe_header, encoding='utf-8')
    print('Opt-in content-free Highlights observations prepared; device results pending')


if __name__ == '__main__':
    main()
