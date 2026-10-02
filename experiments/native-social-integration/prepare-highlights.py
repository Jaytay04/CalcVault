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
ADMISSION_HEADER = 'LiveContainer/CVLPAdmissionMetadata.h'


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('highlights_anchor_drift')
    return text.replace(old, new, 1)


def diagnostic_header_contents():
    header_root = Path(__file__).parents[1] / 'native-social-liveprocess-device'
    return {
        HEADER: (header_root / 'CVLPHighlightsDiagnostics.h').read_text(encoding='utf-8'),
        ADMISSION_HEADER: (header_root / 'CVLPAdmissionMetadata.h').read_text(encoding='utf-8'),
    }


def install_diagnostic_headers(root, headers):
    expected = {HEADER, ADMISSION_HEADER}
    if set(headers) != expected:
        raise ValueError('highlights_header_set_mismatch')
    destinations = [root / relative_path for relative_path in expected]
    if any(path.exists() for path in destinations):
        raise ValueError('highlights_already_present')
    for relative_path, contents in headers.items():
        destination = root / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(contents, encoding='utf-8')


def transform(probe, viewing_experiment=False, direct_viewing_experiment=False,
              early_viewing_experiment=False, admission_metadata=False):
    if sum((viewing_experiment, direct_viewing_experiment, early_viewing_experiment,
            admission_metadata)) > 1:
        raise ValueError('highlights_experiments_mutually_exclusive')
    if ('CVLPHighlightsDiagnostics' in probe or 'CVLPAdmissionMetadata' in probe or
            'CVLP_HIGHLIGHTS_ADMISSION_METADATA' in probe):
        raise ValueError('highlights_already_applied')
    configuration = '#define CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT 1\n' if viewing_experiment else ''
    if direct_viewing_experiment:
        configuration = '#define CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT 1\n'
    if early_viewing_experiment:
        configuration = '#define CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT 1\n'
    if admission_metadata:
        configuration = '#define CVLP_HIGHLIGHTS_ADMISSION_METADATA 1\n'
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
    if admission_metadata:
        probe = once(probe, 'if (!CVLPGuestDiagnosticsLineIsSanitized(line)) { return; }',
                     '#if CVLP_HIGHLIGHTS_ADMISSION_METADATA\n'
                     '    if (!CVLPGuestDiagnosticsLineIsSanitized(line) &&\n'
                     '        !CVLPHighlightsLineIsSanitized(line) &&\n'
                     '        !CVLPAdmissionLineIsSanitized(line)) { return; }\n'
                     '#else\n'
                     '    if (!CVLPGuestDiagnosticsLineIsSanitized(line) &&\n'
                     '        !CVLPHighlightsLineIsSanitized(line)) { return; }\n'
                     '#endif')
    else:
        probe = once(probe, 'if (!CVLPGuestDiagnosticsLineIsSanitized(line)) { return; }',
                     'if (!CVLPGuestDiagnosticsLineIsSanitized(line) &&\n'
                     '        !CVLPHighlightsLineIsSanitized(line)) { return; }')
    marker = 'integration-23-highlights-viewing1' if viewing_experiment else 'integration-23-highlights2'
    if direct_viewing_experiment:
        marker = 'integration-23-highlights-directviewing1'
    if early_viewing_experiment:
        marker = 'integration-23-highlights-earlyviewing1'
    if admission_metadata:
        marker = 'integration-23-highlights-admission2'
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
    parser.add_argument('--admission-metadata', action='store_true',
                        help='Explicit read-only restored-selector metadata discovery; requires diagnostics')
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    if subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip() != PIN:
        raise SystemExit('upstream_revision_mismatch')
    if (root / HEADER).exists() or (root / ADMISSION_HEADER).exists():
        raise SystemExit('highlights_already_present')
    updated = transform((root / PROBE).read_text(encoding='utf-8'), args.viewing_experiment,
                        args.direct_viewing_experiment, args.early_viewing_experiment,
                        args.admission_metadata)
    if args.early_viewing_experiment:
        bootstrap_path = root / 'LiveContainer/LCBootstrap.m'
        probe_header_path = root / 'LiveContainer/CVLPProbe.h'
        bootstrap, probe_header = transform_early_bootstrap(
            bootstrap_path.read_text(encoding='utf-8'),
            probe_header_path.read_text(encoding='utf-8'))
    headers = diagnostic_header_contents()
    (root / PROBE).write_text(updated, encoding='utf-8')
    install_diagnostic_headers(root, headers)
    if args.early_viewing_experiment:
        bootstrap_path.write_text(bootstrap, encoding='utf-8')
        probe_header_path.write_text(probe_header, encoding='utf-8')
    print('Opt-in content-free Highlights observations prepared; device results pending')


if __name__ == '__main__':
    main()
