"""Structural checks for the framework-only full-window guest host layout."""

from pathlib import Path
import unittest


HOST = Path(__file__).with_name("CVLPHostView.swift").read_text(encoding="utf-8")


class FullWindowHostTests(unittest.TestCase):
    def setUp(self):
        self.mount = HOST[
            HOST.index("final class CVLPMountController:"):
            HOST.index("struct CVLPHostView:")
        ]
        self.body = HOST[HOST.index("struct CVLPHostView:"):]

    def test_framework_mode_is_opt_in_and_guest_uses_full_window_surface(self):
        mode = 'Bundle.main.object(forInfoDictionaryKey: "CVLPFrameworkGuestMode") as? Bool == true'
        self.assertGreaterEqual(HOST.count(mode), 2)
        guest_branch = self.body[
            self.body.index("else if model.showingGuest && frameworkGuestMode {"):
            self.body.index("            } else {", self.body.index("else if model.showingGuest && frameworkGuestMode {"))
        ]
        self.assertIn("ZStack(alignment: .topLeading)", guest_branch)
        self.assertIn("CVLPGuestSurface(session: model.guest, onReady: model.surfaceReady).ignoresSafeArea()",
                      guest_branch)
        self.assertNotIn("Native lifecycle test", guest_branch)

    def test_framework_lock_overlay_reuses_existing_lock_action_and_is_reachable(self):
        action = 'Button("Lock") { reportVisible = false; model.lock() }'
        guest_branch = self.body[
            self.body.index("else if model.showingGuest && frameworkGuestMode {"):
            self.body.index("            } else {", self.body.index("else if model.showingGuest && frameworkGuestMode {"))
        ]
        self.assertIn(action, guest_branch)
        self.assertIn(".frame(minHeight: 44)", guest_branch)
        self.assertIn(".foregroundStyle(.white)", guest_branch)
        self.assertIn(".background(Color.black.opacity(0.9), in: Capsule())", guest_branch)
        legacy_branch = self.body[self.body.index("            } else {", self.body.index("else if model.showingGuest && frameworkGuestMode {")):]
        self.assertIn(action, legacy_branch)
        self.assertIn('Text("Native lifecycle test', legacy_branch)
        self.assertIn("if model.showingGuest { CVLPGuestSurface(session: model.guest, onReady: model.surfaceReady) }",
                      legacy_branch)

    def test_mount_sizes_and_clips_only_in_framework_mode(self):
        load = self.mount[
            self.mount.index("override func viewDidLoad()"):
            self.mount.index("override func viewDidLayoutSubviews()")
        ]
        self.assertIn("if frameworkGuestMode { view.clipsToBounds = true }", load)
        layout = self.mount[
            self.mount.index("override func viewDidLayoutSubviews()"):
            self.mount.index("override func viewDidAppear")
        ]
        self.assertIn("guard frameworkGuestMode,", layout)
        self.assertIn("session.viewController.viewIfLoaded", layout)
        self.assertIn("childView.frame = view.bounds", layout)
        self.assertNotIn(".transform", self.mount)

    def test_fit_marker_is_static_once_only_and_requires_attached_full_window_match(self):
        layout = self.mount[
            self.mount.index("override func viewDidLayoutSubviews()"):
            self.mount.index("override func viewDidAppear")
        ]
        marker = 'NSLog("CVLP_FULL_WINDOW_HOST_FIT")'
        self.assertEqual(HOST.count(marker), 1)
        self.assertIn("!fullWindowFitLogged", layout)
        for condition in (
            "let window = view.window",
            "!view.bounds.isEmpty",
            "childView.bounds.size == view.bounds.size",
            "view.convert(view.bounds, to: window)",
            "abs(mountInWindow.minX - windowBounds.minX) <= 1",
            "abs(mountInWindow.minY - windowBounds.minY) <= 1",
            "abs(mountInWindow.width - windowBounds.width) <= 1",
            "abs(mountInWindow.height - windowBounds.height) <= 1",
        ):
            self.assertIn(condition, layout)
        self.assertLess(layout.index("fullWindowFitLogged = true"), layout.index(marker))

    def test_ready_callback_remains_once_after_attached_nonempty_appearance(self):
        appear = self.mount[
            self.mount.index("override func viewDidAppear"):]
        self.assertIn("guard !started, view.window != nil, !view.bounds.isEmpty else { return }", appear)
        self.assertEqual(appear.count("onReady()"), 1)
        self.assertLess(appear.index("started = true"), appear.index("onReady()"))


if __name__ == "__main__":
    unittest.main()
