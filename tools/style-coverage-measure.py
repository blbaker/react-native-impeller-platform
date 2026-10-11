#!/usr/bin/env python3
"""Score the style-coverage probe frames (fixtures/style-coverage, fixtures/nw-coverage).

usage: style-coverage-measure.py <scene>=<frame.ppm>[,<fixture.js>] ...
  scenes: g2, risky (fixtures/style-coverage), nw (fixtures/nw-coverage)

Each tile has a CONTROL slot (cell + 30,45) and a FEATURE slot (cell + 150,45).
BASE rule: e:'diff' tiles must differ from the control, e:'same' tiles must
match it. STRICT rules (tools/style_coverage_rules.py, keyed "<scene>:<id>")
judge what the feature slot actually painted; a tile with a strict rule PASSes
only when both hold. Output, one line per tile:
  TILE <scene> <n> <id> <PASS|FAIL> base=<ok|no> diffpx=<n> strict=<-|ok|no:<why>>
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import style_coverage_rules as R  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE = {
    'g2': 'fixtures/style-coverage/index.js',
    'risky': 'fixtures/style-coverage/index.js',
    'nw': 'fixtures/nw-coverage/index.js',
}


def tiles_of(scene, path):
    src = open(path).read()
    if scene in ('g2', 'risky'):
        split = src.find('const RISKY')
        src = src[split:] if scene == 'risky' else src[:split]
    else:
        src = src[:src.find('const VARIANTS')]
    return re.findall(r"\{ ?id: '([A-Za-z0-9]+)', e: '(diff|same)'", src)


# NativeWind variant tiles (fixtures/nw-coverage probe://variants): the
# feature slot's centre must be red-500 when the variant should match and the
# grey base when it should not. ios:/android: never match on impeller (it is
# neither); motion-safe:/motion-reduce: are react-native-css limits (no
# prefers-reduced-motion matcher) and are not judged.
VARIANTS = ['ios', 'android', 'native', 'web', 'md', 'xl', 'max-md', 'landscape',
            'portrait', 'dark', 'motion-safe', 'motion-reduce', 'ltr', 'rtl',
            'contrast-more', '@container']
VARIANT_RED = {
    'variants-light': {'native', 'md', 'landscape', 'ltr', '@container'},
    'variants-dark': {'native', 'md', 'landscape', 'ltr', '@container', 'dark'},
    'variants-600': {'max-md', '@container', 'native', 'portrait', 'ltr'},
}
SKIP_VARIANTS = {'motion-safe', 'motion-reduce'}
# probe://interact sample points, and which ones each windowed case turns red.
INTERACT_PTS = {'hoverBox': (60, 60), 'pressBox': (160, 60), 'groupChild': (240, 40),
                'focusBorder': (22, 140), 'disabledBox': (260, 140)}
INTERACT_RED = {
    'idle': {'disabledBox'}, 'hover': {'hoverBox', 'disabledBox'},
    'groupHover': {'groupChild', 'disabledBox'}, 'active': {'pressBox', 'disabledBox'},
    'focus': {'focusBorder', 'disabledBox'},
}


def score_variants(scene, frame):
    bad = 0
    for n, v in enumerate(VARIANTS):
        feat = frame.slot(n, 'f')
        if not feat.in_frame() or v in SKIP_VARIANTS:
            continue
        p = feat.px(30, 30)
        want = v in VARIANT_RED[scene]
        got = R.is_red(p)
        ok = want == got and (got or R.near(p, (209, 213, 220), 30))
        bad += 0 if ok else 1
        print(f"TILE {scene} {n+1} {v} {'PASS' if ok else 'FAIL'} want={'red' if want else 'grey'} px={p}".replace(' (', '_(').replace(', ', ','))
    return bad


def score_interact(case, frame):
    reds = INTERACT_RED[case]
    bad_pts = []
    for k, (x, y) in INTERACT_PTS.items():
        p = frame.at(x, y)
        want = k in reds
        if want != R.is_red(p) or (not want and not R.near(p, (43, 127, 255), 30)):
            bad_pts.append(f"{k}={p[0]},{p[1]},{p[2]}")
    ok = not bad_pts
    print(f"TILE interact 0 {case} {'PASS' if ok else 'FAIL'} bad={';'.join(bad_pts) or '-'}")
    return 0 if ok else 1


def main():
    total_fail = 0
    for arg in sys.argv[1:]:
        scene, rest = arg.split('=', 1)
        if scene in VARIANT_RED:
            total_fail += score_variants(scene, R.Frame(rest))
            continue
        if scene.startswith('interact-'):
            total_fail += score_interact(scene[len('interact-'):], R.Frame(rest))
            continue
        ppm, _, fixture = rest.partition(',')
        fixture = fixture or os.path.join(ROOT, FIXTURE[scene])
        frame = R.Frame(ppm)
        for n, (tid, exp) in enumerate(tiles_of(scene, fixture)):
            ctl, feat = frame.slot(n, 'c'), frame.slot(n, 'f')
            if not feat.in_frame():
                print(f"TILE {scene} {n+1} {tid} FAIL base=no diffpx=-1 strict=no:off-frame")
                total_fail += 1
                continue
            d = R.diff_count(ctl, feat)
            base_ok = (d > 8) == (exp == 'diff')
            rule = R.RULES.get(f"{scene}:{tid}")
            strict = '-'
            ok = base_ok
            if rule is not None:
                try:
                    s_ok, why = rule(ctl, feat)
                except Exception as e:  # a crashing rule is a FAIL, never a pass
                    s_ok, why = False, f"rule-crashed:{type(e).__name__}:{e}"
                strict = 'ok' if s_ok else 'no:' + str(why).replace(' ', '_')[:120]
                ok = ok and s_ok
                if s_ok and why:
                    strict = 'ok:' + str(why).replace(' ', '_')[:120]
            total_fail += 0 if ok else 1
            print(f"TILE {scene} {n+1} {tid} {'PASS' if ok else 'FAIL'} "
                  f"base={'ok' if base_ok else 'no'} diffpx={d} strict={strict}")
    print(f"TILES_FAILING {total_fail}")


if __name__ == '__main__':
    main()
