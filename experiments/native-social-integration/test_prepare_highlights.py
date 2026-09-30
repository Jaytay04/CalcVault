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
        self.assertIn('Build marker: integration-23-highlights1.', updated)
        self.assertIn('!CVLPHighlightsLineIsSanitized(line)', updated)
        self.assertIn('[CVLPHighlightsDiagnostics start];', updated)
        self.assertIn('untouched_report_transport();', updated)
        self.assertIn('// credential, bookmark and lifecycle sentinel', updated)

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
        self.assertIn('ditto "$device_host" "$output/Payload/LiveContainer.app"', script)
        self.assertNotIn('ditto "$fixture_app"', script)
        workflow = (root.parents[1] / '.github/workflows/native-social-integration.yml').read_text()
        self.assertEqual(workflow.count('default: false'), 2)
        self.assertIn('if: inputs.highlights_diagnostics', workflow)


if __name__ == '__main__':
    unittest.main()
