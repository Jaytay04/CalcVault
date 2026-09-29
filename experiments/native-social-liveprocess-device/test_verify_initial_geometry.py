import unittest
from pathlib import Path

from verify_initial_geometry import verify


class InitialGeometryVerificationTests(unittest.TestCase):
    def line(self, dimensions="402 874 402 874", root="0"):
        sw, sh, ww, wh = dimensions.split()
        return ("log prefix CVLP_INITIAL_GUEST_GEOMETRY "
                f"sceneW={sw} sceneH={sh} windowW={ww} windowH={wh} rootAssigned={root}")

    def test_valid(self):
        self.assertTrue(verify(self.line()).startswith("PASS:"))

    def test_bad_dimensions_or_root_fail(self):
        for dimensions in ("0 0 0 0", "402 874 0 0", "402 874 874 402",
                           "nan 874 402 874", "inf 874 inf 874", "-402 874 -402 874"):
            with self.subTest(dimensions=dimensions), self.assertRaises(ValueError):
                verify(self.line(dimensions))
        with self.assertRaises(ValueError):
            verify(self.line(root="1"))

    def test_missing_duplicate_or_malformed_fail(self):
        for text in ("", self.line() + "\n" + self.line(),
                     self.line().replace("sceneW=402", "sceneW=bad"), self.line() + " unexpected"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                verify(text)

    def test_fixture_observes_before_root_without_window_repair(self):
        source = Path(__file__).with_name("Guest.m").read_text(encoding="utf-8")
        start = source.index("UIWindowScene *windowScene = (UIWindowScene *)scene;")
        end = source.index('[self.window makeKeyAndVisible];', start)
        block = source[start:end]
        self.assertLess(block.index("CVLP_INITIAL_GUEST_GEOMETRY"),
                        block.index("self.window.rootViewController ="))
        self.assertEqual(block.count("self.window.frame ="), 1)
        self.assertIn("self.window.frame = windowScene.coordinateSpace.bounds;", block)
        self.assertNotIn("UIScreen", block)


if __name__ == "__main__":
    unittest.main()
