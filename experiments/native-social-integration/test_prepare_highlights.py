import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('highlights_adapter', Path(__file__).with_name('prepare-highlights.py'))
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


def source():
    return '''#import "CVLPGuestDiagnostics.h"
+ (void)startGuestGeometryObservations {
    [CVLPGuestGeometryDiagnostics start];
}
+ (void)recordGuestDiagnostic:(NSString *)line {
    if (!CVLPGuestDiagnosticsLineIsSanitized(line)) { return; }
    untouched_report_transport();
}
// Build marker: integration-23.
// credential, bookmark and lifecycle sentinel
'''


class HighlightsAdapterTests(unittest.TestCase):
    def test_only_explicit_anchors_change(self):
        original = source()
        updated = adapter.transform(original)
        self.assertEqual(original, source())
        self.assertIn('Build marker: integration-23-highlights2.', updated)
        self.assertIn('!CVLPHighlightsLineIsSanitized(line)', updated)
        self.assertNotIn('CVLPAdmissionLineIsSanitized', updated)
        self.assertIn('[CVLPHighlightsDiagnostics start];', updated)
        self.assertIn('untouched_report_transport();', updated)
        self.assertIn('// credential, bookmark and lifecycle sentinel', updated)
        self.assertNotIn('#define CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT', updated)

    def test_viewing_experiment_is_explicit_and_separately_marked(self):
        updated = adapter.transform(source(), viewing_experiment=True)
        self.assertIn('#define CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT 1\n#import "CVLPHighlightsDiagnostics.h"', updated)
        self.assertIn('Build marker: integration-23-highlights-viewing1.', updated)
        self.assertNotIn('Build marker: integration-23-highlights2.', updated)
        self.assertIn('// credential, bookmark and lifecycle sentinel', updated)
        with self.assertRaises(ValueError):
            adapter.transform(updated, viewing_experiment=True)

    def test_direct_viewing_experiment_has_independent_opt_in(self):
        updated = adapter.transform(source(), direct_viewing_experiment=True)
        self.assertIn('#define CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT 1\n#import "CVLPHighlightsDiagnostics.h"', updated)
        self.assertIn('Build marker: integration-23-highlights-directviewing1.', updated)
        self.assertNotIn('#define CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT', updated)
        self.assertIn('// credential, bookmark and lifecycle sentinel', updated)
        with self.assertRaisesRegex(ValueError, 'mutually_exclusive'):
            adapter.transform(source(), viewing_experiment=True, direct_viewing_experiment=True)

    def test_reapplication_and_anchor_drift_fail(self):
        with self.assertRaises(ValueError):
            adapter.transform(adapter.transform(source()))
        for anchor in ('#import "CVLPGuestDiagnostics.h"',
                       '    [CVLPGuestGeometryDiagnostics start];',
                       'if (!CVLPGuestDiagnosticsLineIsSanitized(line)) { return; }',
                       'Build marker: integration-23.'):
            with self.subTest(anchor=anchor):
                for replacement in ('missing', anchor + anchor):
                    with self.assertRaises(ValueError):
                        adapter.transform(source().replace(anchor, replacement))

    def test_early_is_independent_and_mutually_exclusive(self):
        updated = adapter.transform(source(), early_viewing_experiment=True)
        self.assertIn('#define CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT 1', updated)
        self.assertIn('integration-23-highlights-earlyviewing1', updated)
        self.assertIn('[CVLPHighlightsDiagnostics armEarlyViewing]', updated)
        self.assertIn('[CVLPHighlightsDiagnostics finishEarlyViewingLoad]', updated)
        for option in ('viewing_experiment', 'direct_viewing_experiment'):
            with self.assertRaisesRegex(ValueError, 'mutually_exclusive'):
                adapter.transform(source(), early_viewing_experiment=True, **{option: True})

    def test_admission_metadata_is_independent_and_fail_closed(self):
        updated = adapter.transform(source(), admission_metadata=True)
        self.assertIn('#define CVLP_HIGHLIGHTS_ADMISSION_METADATA 1', updated)
        self.assertIn('Build marker: integration-23-highlights-admission2.', updated)
        self.assertNotIn('Build marker: integration-23-highlights-admission1.', updated)
        self.assertIn('#if CVLP_HIGHLIGHTS_ADMISSION_METADATA\n'
                      '    if (!CVLPGuestDiagnosticsLineIsSanitized(line) &&\n'
                      '        !CVLPHighlightsLineIsSanitized(line) &&\n'
                      '        !CVLPAdmissionLineIsSanitized(line)) { return; }\n'
                      '#else\n'
                      '    if (!CVLPGuestDiagnosticsLineIsSanitized(line) &&\n'
                      '        !CVLPHighlightsLineIsSanitized(line)) { return; }\n'
                      '#endif', updated)
        self.assertEqual(updated.count('CVLPAdmissionLineIsSanitized(line)'), 1)
        self.assertNotIn('#define CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT', updated)
        self.assertNotIn('#define CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT', updated)
        self.assertNotIn('#define CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT', updated)
        with self.assertRaises(ValueError):
            adapter.transform(updated, admission_metadata=True)
        for option in ('viewing_experiment', 'direct_viewing_experiment',
                       'early_viewing_experiment'):
            with self.subTest(option=option):
                with self.assertRaisesRegex(ValueError, 'mutually_exclusive'):
                    adapter.transform(source(), admission_metadata=True,
                                      **{option: True})

    def test_owner_metadata_is_independent_and_uses_its_own_sanitizer(self):
        updated = adapter.transform(source(), owner_metadata=True)
        self.assertIn('#define CVLP_HIGHLIGHTS_ADMISSION_METADATA 1\n'
                      '#define CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA 1\n'
                      '#import "CVLPHighlightsDiagnostics.h"', updated)
        self.assertIn('Build marker: integration-23-highlights-owner1.', updated)
        self.assertNotIn('Build marker: integration-23-highlights-admission2.', updated)
        self.assertIn('#if CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA\n'
                      '    if (!CVLPGuestDiagnosticsLineIsSanitized(line) &&\n'
                      '        !CVLPHighlightsLineIsSanitized(line) &&\n'
                      '        !CVLPAdmissionLineIsSanitized(line) &&\n'
                      '        !CVLPAdmissionOwnerLineIsSanitized(line)) { return; }\n'
                      '#else\n'
                      '    if (!CVLPGuestDiagnosticsLineIsSanitized(line) &&\n'
                      '        !CVLPHighlightsLineIsSanitized(line)) { return; }\n'
                      '#endif', updated)
        self.assertNotIn('#define CVLP_HIGHLIGHTS_VIEWING_EXPERIMENT', updated)
        self.assertNotIn('#define CVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT', updated)
        self.assertNotIn('#define CVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT', updated)
        with self.assertRaises(ValueError):
            adapter.transform(updated, owner_metadata=True)
        for option in ('viewing_experiment', 'direct_viewing_experiment',
                       'early_viewing_experiment', 'admission_metadata'):
            with self.subTest(option=option):
                with self.assertRaisesRegex(ValueError, 'mutually_exclusive'):
                    adapter.transform(source(), owner_metadata=True,
                                      **{option: True})

    def test_diagnostic_adapter_installs_all_headers_and_rejects_partial_reapply(self):
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            contents = {
                adapter.HEADER: 'highlights header',
                adapter.ADMISSION_HEADER: 'admission header',
                adapter.ADMISSION_OWNER_HEADER: 'owner admission header',
            }
            adapter.install_diagnostic_headers(root, contents)
            self.assertEqual((root / adapter.HEADER).read_text(), 'highlights header')
            self.assertEqual((root / adapter.ADMISSION_HEADER).read_text(), 'admission header')
            self.assertEqual((root / adapter.ADMISSION_OWNER_HEADER).read_text(), 'owner admission header')
            with self.assertRaisesRegex(ValueError, 'already_present'):
                adapter.install_diagnostic_headers(root, contents)
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / adapter.ADMISSION_OWNER_HEADER).parent.mkdir(parents=True)
            (root / adapter.ADMISSION_OWNER_HEADER).write_text('preexisting owner admission header')
            with self.assertRaisesRegex(ValueError, 'already_present'):
                adapter.install_diagnostic_headers(root, contents)

    def test_adapter_sources_all_headers_for_every_diagnostic_build(self):
        headers = adapter.diagnostic_header_contents()
        self.assertEqual(set(headers), {adapter.HEADER, adapter.ADMISSION_HEADER,
                                        adapter.ADMISSION_OWNER_HEADER})
        self.assertIn('CVLPAdmissionLineIsSanitized', headers[adapter.ADMISSION_HEADER])
        owner_header = headers[adapter.ADMISSION_OWNER_HEADER]
        self.assertIn('#define CVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA 0', owner_header)
        self.assertIn('CVLPAdmissionOwnerMetadataLineForAnchor', owner_header)
        self.assertIn('CVLPAdmissionOwnerLineIsSanitized', owner_header)
        import inspect
        main_source = inspect.getsource(adapter.main)
        self.assertIn('headers = diagnostic_header_contents()', main_source)
        self.assertIn('install_diagnostic_headers(root, headers)', main_source)

    def test_early_load_scope_and_fail_closed_anchors(self):
        call = '        appHandle = dlopen_nolock(appExecPath, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);'
        original = 'credential_checks();\n' + call + '\nloader_failure_checks();'
        bootstrap, header = adapter.transform_early_bootstrap(original, '@interface CVLPProbe\n@end')
        self.assertLess(bootstrap.index('credential_checks'), bootstrap.index('armEarlyHighlightsViewing'))
        self.assertLess(bootstrap.index('armEarlyHighlightsViewing'), bootstrap.index('dlopen_nolock'))
        self.assertLess(bootstrap.index('dlopen_nolock'), bootstrap.index('@finally'))
        self.assertLess(bootstrap.index('finishEarlyHighlightsViewingLoad'), bootstrap.index('loader_failure_checks'))
        self.assertEqual(bootstrap.count('dlopen_nolock'), 1)
        self.assertIn('+ (void)armEarlyHighlightsViewing;', header)
        for replacement in ('missing', call + call):
            with self.assertRaises(ValueError):
                adapter.transform_early_bootstrap(original.replace(call, replacement), '@end')
        with self.assertRaises(ValueError):
            adapter.transform_early_bootstrap(original, '@end\n@end')

    def test_standard_preparation_does_not_enable_diagnostics(self):
        root = Path(__file__).parent
        self.assertNotIn('CVLPHighlights', (root / 'prepare-integration.py').read_text())
        self.assertNotIn('CVLPHighlights', (root.parent / 'native-social-liveprocess-device' /
                                          'prepare-framework-guest.py').read_text())

    def test_fixture_is_opt_in_and_outside_packaged_app(self):
        root = Path(__file__).parent
        script = (root / 'build.sh').read_text()
        self.assertIn('if [[ "${CV_HIGHLIGHTS_DIAGNOSTICS:-0}" == 1 ]]; then', script)
        self.assertIn('fixture_app="$work/HighlightsDiagnosticsFixture.app"', script)
        self.assertIn('-o "$fixture_app/HighlightsDiagnosticsFixture"', script)
        self.assertIn('simctl install "$simulator" "$fixture_app"', script)
        self.assertIn('org.example.synthetic.highlights-observer-tests', script)
        self.assertIn('fixture_result_name="cv-highlights-$(uuidgen)-$fixture_mode.result"', script)
        self.assertIn('test ! -e "$fixture_result"', script)
        self.assertIn('SIMCTL_CHILD_CV_HIGHLIGHTS_RESULT_NAME="$fixture_result_name"', script)
        self.assertIn('for fixture_result_attempt in {1..30}; do', script)
        self.assertIn('CV_HIGHLIGHTS_FIXTURE_PASS viewing=$viewing_mode direct=$((direct_mode || early_mode)) early=$early_mode admission=$admission_mode owner=$owner_mode admissionCases=1 ownerCases=1 replayTerminal=$early_replay_only', script)
        self.assertIn('cp "$fixture_result" "$evidence/highlights-fixture$fixture_suffix-result.log"', script)
        self.assertIn('for fixture_mode in 0 1 2 3 4 5 6; do', script)
        self.assertIn('owner_mode=0', script)
        self.assertIn('early_replay_only=0', script)
        self.assertIn('if [[ "$fixture_mode" == 4 ]]; then early_mode=1; early_replay_only=1; fixture_suffix="-earlyreplay"; fi', script)
        self.assertIn('SIMCTL_CHILD_CV_HIGHLIGHTS_EARLY_REPLAY_ONLY="$early_replay_only"', script)
        self.assertNotIn("grep -Fq 'CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=exact-target-replay-terminal'", script)
        self.assertIn('-DCVLP_HIGHLIGHTS_VIEWING_EXPERIMENT="$viewing_mode"', script)
        self.assertIn('-DCVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT="$direct_mode"', script)
        self.assertIn('-DCVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT="$early_mode"', script)
        self.assertIn('-DCVLP_HIGHLIGHTS_ADMISSION_METADATA="$admission_mode"', script)
        self.assertIn('-DCVLP_HIGHLIGHTS_ADMISSION_OWNER_METADATA="$owner_mode"', script)
        self.assertIn('if [[ "$fixture_mode" == 6 ]]; then admission_mode=1; owner_mode=1; fixture_suffix="-owner"; fi', script)
        self.assertNotIn("grep -Fq 'CV_ADMISSION_METADATA_FIXTURE_PASS'", script)
        self.assertIn('ditto "$device_host" "$output/Payload/LiveContainer.app"', script)
        self.assertNotIn('ditto "$fixture_app"', script)
        workflow = (root.parents[1] / '.github/workflows/native-social-integration.yml').read_text()
        self.assertEqual(workflow.count('default: false'), 16)
        self.assertEqual(workflow.count('highlights_admission_owner_metadata:'), 2)
        self.assertIn('if: inputs.highlights_diagnostics', workflow)
        entry = (root.parents[1] / '.github/workflows/native-social-liveprocess-device.yml').read_text()
        self.assertIn('highlights_diagnostics: ${{ inputs.highlights_diagnostics }}', entry)
        self.assertIn('if: ${{ inputs.integration_guest }}', entry)
        self.assertIn('highlights_viewing_experiment: ${{ inputs.highlights_viewing_experiment }}', entry)
        self.assertIn('test "$VIEWING" != true || test "$DIAGNOSTICS" = true', workflow)
        self.assertIn('test "$VIEWING" != true && test "$DIAGNOSTICS" != true && test "$DIRECT" != true', entry)
        self.assertIn('highlights_direct_viewing_experiment: ${{ inputs.highlights_direct_viewing_experiment }}', entry)
        self.assertIn('test "$DIRECT" != true || test "$DIAGNOSTICS" = true', workflow)
        self.assertIn('test "$DIRECT" != true || test "$VIEWING" != true', workflow)
        self.assertIn('highlights_early_viewing_experiment: ${{ inputs.highlights_early_viewing_experiment }}', entry)
        self.assertIn('highlights_admission_metadata: ${{ inputs.highlights_admission_metadata }}', entry)
        self.assertIn('highlights_admission_owner_metadata: ${{ inputs.highlights_admission_owner_metadata }}', entry)
        self.assertIn('OWNER: ${{ inputs.highlights_admission_owner_metadata }}', entry)
        self.assertIn('test "$OWNER" != true', entry)
        self.assertIn('ADMISSION: ${{ inputs.highlights_admission_metadata }}', workflow)
        self.assertIn('test "$ADMISSION" != true || test "$DIAGNOSTICS" = true', workflow)
        self.assertIn('test "$ADMISSION" != true || test "$EARLY" != true', workflow)
        self.assertIn('test "$ADMISSION" != true || test "$DIRECT" != true', workflow)
        self.assertIn('test "$ADMISSION" != true || test "$VIEWING" != true', workflow)
        self.assertIn('args+=(--admission-metadata)', workflow)
        self.assertIn('args+=(--admission-owner-metadata)', workflow)
        self.assertIn('OWNER: ${{ inputs.highlights_admission_owner_metadata }}', workflow)
        self.assertIn('test "$OWNER" != true || test "$DIAGNOSTICS" = true', workflow)
        self.assertIn('test "$OWNER" != true || test "$ADMISSION" != true', workflow)
        self.assertIn('test "$OWNER" != true || test "$EARLY" != true', workflow)
        self.assertIn('test "$OWNER" != true || test "$DIRECT" != true', workflow)
        self.assertIn('test "$OWNER" != true || test "$VIEWING" != true', workflow)
        self.assertNotIn("'-highlights-admission1'", workflow)
        self.assertIn("'-highlights-admission2'", workflow)
        self.assertIn("'-highlights-owner1'", workflow)
        self.assertEqual(workflow.count("'-highlights-owner1'"), 2)
        self.assertIn('highlights_admission_metadata:', entry)
        self.assertIn('test "$ADMISSION" != true', entry)
        self.assertIn('test "$EARLY" != true || test "$DIAGNOSTICS" = true', workflow)
        self.assertIn('test "$EARLY" != true || test "$DIRECT" != true', workflow)
        self.assertIn('test "$EARLY" != true || test "$VIEWING" != true', workflow)


if __name__ == '__main__':
    unittest.main()
