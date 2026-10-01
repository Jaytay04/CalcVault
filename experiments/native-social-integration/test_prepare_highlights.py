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
        self.assertIn("grep -q '^CV_HIGHLIGHTS_FIXTURE_PASS$'", script)
        self.assertIn('for fixture_mode in 0 1 2; do', script)
        self.assertIn('-DCVLP_HIGHLIGHTS_VIEWING_EXPERIMENT="$viewing_mode"', script)
        self.assertIn('-DCVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT="$direct_mode"', script)
        self.assertIn('ditto "$device_host" "$output/Payload/LiveContainer.app"', script)
        self.assertNotIn('ditto "$fixture_app"', script)
        workflow = (root.parents[1] / '.github/workflows/native-social-integration.yml').read_text()
        self.assertEqual(workflow.count('default: false'), 6)
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


if __name__ == '__main__':
    unittest.main()
