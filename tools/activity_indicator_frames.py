"""ci-activity-indicator.sh helper: compare the ActivityIndicator tile of two
windowed grid-1 captures (frame 0 and ~1 s later). Prints ACTIVITY_FRAMES_OK or
ACTIVITY_FRAMES_FAIL <reason>. Usage: activity_indicator_frames.py FRAME0.ppm FRAME1.ppm"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
f0, f1 = sys.argv[1:3]


def load(ppm):
    sys.argv = ["m", ppm, str(ROOT / "fixtures/style-audit/index.js")]
    spec = importlib.util.spec_from_file_location("m", ROOT / "tools/style-audit-measure.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m, m.pixels(m.IDS.index("activityIndicator"), "f"), m.pixels(m.IDS.index("activityIndicator"), "c")


def main():
    m0, a, ca = load(f0)
    _, b, cb = load(f1)
    from style_audit_rules_sc28 import spinner_ok
    for name, frame, ctl in (("frame0", a, ca), ("frame1", b, cb)):
        if not spinner_ok(ctl, frame, 0):
            print(f"ACTIVITY_FRAMES_FAIL {name} is not a 12-spoke red spinner (n={m0.stats(frame)['n']})")
            return 1
    d = m0.diff(a, b)
    if d < 40:
        print(f"ACTIVITY_FRAMES_FAIL frame at ~1 s differs from frame 0 in only {d} px")
        return 1
    print(f"ACTIVITY_FRAMES_OK diff_px={d}")
    return 0


sys.exit(main())
