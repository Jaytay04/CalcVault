"""Structural checks for the simulator-only portrait policy regression."""
from pathlib import Path
import unittest


class PortraitPolicyTests(unittest.TestCase):
    def test_probe_is_framework_simulator_only_and_preserves_lock_authority(self):
        source = Path(__file__).with_name('CVLPHostView.swift').read_text(encoding='utf-8')
        start = source.index('== "portrait",')
        end = source.index('#endif', start)
        block = source[start:end]
        self.assertGreater(source.rfind('#if targetEnvironment(simulator)', 0, start),
                           source.rfind('#endif', 0, start))
        self.assertIn('"CVLPFrameworkGuestMode") as? Bool == true', block)
        self.assertEqual(block.count('self.gate.accepts(token: token)'), 2)
        self.assertEqual(block.count('UIApplication.shared.applicationState == .active'), 2)
        self.assertIn('scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))', block)
        self.assertIn('scene.interfaceOrientation == .portrait', block)
        self.assertIn('view.bounds.size == window.bounds.size', block)
        self.assertIn('self.lock(reason: "simulator portrait policy test")', block)
        self.assertIn('if gate.phase != .preparing { lock(reason: "inactive") }', source)

    def test_startup_adapter_does_not_apply_abandoned_rotation_patch(self):
        source = Path(__file__).with_name('prepare-framework-guest.py').read_text(encoding='utf-8')
        self.assertNotIn('framework_rotation', source)
        self.assertIn('framework_initial_geometry.transform(framework_geometry.transform', source)
        self.assertIn('build20-framework-portrait1', source)


if __name__ == '__main__':
    unittest.main()
