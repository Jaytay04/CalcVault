"""Require nonzero synthetic scene/window geometry before root assignment."""
import math
from pathlib import Path
import re
import sys

MARKER = "CVLP_INITIAL_GUEST_GEOMETRY "
FIELDS = re.compile(r"sceneW=(\S+) sceneH=(\S+) windowW=(\S+) windowH=(\S+) rootAssigned=(\d+)\s*$")


def verify(text):
    samples = [line.split(MARKER, 1)[1] for line in text.splitlines() if MARKER in line]
    if len(samples) != 1:
        raise ValueError("expected_one_initial_geometry_sample")
    match = FIELDS.fullmatch(samples[0])
    if not match:
        raise ValueError("malformed_initial_geometry")
    dimensions = [float(value) for value in match.groups()[:4]]
    if not all(math.isfinite(value) and value > 0 for value in dimensions):
        raise ValueError("initial_geometry_not_positive_finite")
    sw, sh, ww, wh = dimensions
    if abs(sw - ww) > 0.5 or abs(sh - wh) > 0.5:
        raise ValueError("initial_window_scene_mismatch")
    if match.group(5) != "0":
        raise ValueError("root_already_assigned")
    return "PASS: synthetic scene/window nonzero before root assignment"


if __name__ == "__main__":
    print(verify(Path(sys.argv[1]).read_text(encoding="utf-8")))
