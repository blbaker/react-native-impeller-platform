#!/usr/bin/env python3
"""FP-32: judge one ci-context-loss arm.  usage: context_loss_check.py DIR TAG LOSSES OFFSCREEN

DIR holds run.log, ref.ppm (the frame presented at the first forced loss),
loss<k>-<j>.ppm (present j = 1..3 after recovery k) and final.ppm. OFFSCREEN is
which supersample cache the run must have dropped: tree (root offscreen), svg
(per-<Svg> offscreen) or none. Prints "<TAG>: OK ..." or exits 1 with
CONTEXT_LOSS_FAIL naming the defect.
"""
import os
import re
import sys

DIR, TAG, LOSSES, OFFSCREEN = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
BOXES = {  # fixture coordinates (window 400x300 at --scale 1)
    "image": (10, 10, 160, 120),
    "text": (190, 10, 200, 60),
    "svg": (190, 80, 100, 100),
    "world": (10, 150, 200, 140),
}
TOL = 8          # per-channel difference that counts a pixel as changed
MAX_OFF = 0.001  # fraction of a frame allowed to differ (AA noise); 0 on llvmpipe so far


def bad(msg):
    print("CONTEXT_LOSS_FAIL: %s: %s" % (TAG, msg), file=sys.stderr)
    sys.exit(1)


def ppm(path):
    if not os.path.exists(path):
        bad("missing capture %s" % os.path.basename(path))
    data = open(path, "rb").read()
    parts = data.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


log = open(os.path.join(DIR, "run.log"), errors="replace").read()

# 1. the engine's own account of the losses
lost = re.findall(r"^rn-impeller: context_loss n=(\d+) reason=(\w+) present=(\d+)", log, re.M)
if len(lost) != LOSSES:
    bad("%d context_loss lines, wanted %d (the test hook or detection did not fire)" % (len(lost), LOSSES))
if any(r != "test_hook" for _, r, _ in lost):
    bad("unexpected loss reasons %s" % sorted({r for _, r, _ in lost}))
restores = re.findall(r"^rn-impeller: context_restore n=\d+ ok=(\d) ", log, re.M)
if restores.count("1") != LOSSES or "0" in restores:
    bad("restores ok=%s, wanted %d successful rebuilds" % (restores, LOSSES))
firsts = re.findall(r"^rn-impeller: context_restore_present n=\d+ present=(\d+)", log, re.M)
if len(firsts) != LOSSES:
    bad("%d presents after a recovery, wanted %d" % (len(firsts), LOSSES))
summ = re.search(r"^rn-impeller: context_loss_summary losses=(\d+) recoveries=(\d+) failed_rebuilds=(\d+) "
                 r"extra_reports=\d+ dropped=\d+ max_rebuild_us=(\d+) lost_at_exit=(\d)", log, re.M)
if not summ:
    bad("no context_loss_summary line")
if summ.group(1, 2, 3, 5) != (str(LOSSES), str(LOSSES), "0", "0"):
    bad("summary %s" % summ.group(0))
drops = re.findall(r"^rn-impeller: context_loss_drop images=(\d+) svg=(\d+) world=(\d+) sprites=(\d+) tree=(\d)",
                   log, re.M)
if len(drops) != LOSSES:
    bad("%d context_loss_drop lines, wanted %d (RECORD caches never dropped)" % (len(drops), LOSSES))
for i, (img, svg, world, spr, tree) in enumerate(drops, 1):
    if int(img) < 1 or int(world) < 1 or int(spr) < 2:
        bad("loss %d dropped images=%s world=%s sprites=%s: the fixture's textures were not cached" % (i, img, world, spr))
    if OFFSCREEN == "tree" and tree != "1":
        bad("loss %d: no root supersample texture to drop at --supersample-rnsvg 4" % i)
    if OFFSCREEN == "svg" and int(svg) < 1:
        bad("loss %d: no per-<Svg> offscreen texture to drop at --supersample-rnsvg 1" % i)
typo = re.search(r"^rn-impeller: typography_rebuild generations=(\d+) own_rebuilt=(\d+)", log, re.M)
if not typo or int(typo.group(1)) != LOSSES:
    bad("typography generations %s, wanted %d" % (typo.group(1) if typo else None, LOSSES))
if int(typo.group(2)) < 1:
    bad("no thread rebuilt its own typography context (JS measure kept the old one)")
io_ok = len(re.findall(r"^rn-impeller: io_context ok=1 ", log, re.M))
if io_ok != LOSSES + 1:
    bad("io_context ok=1 %d times, wanted %d (start + one per rebuild): the IO upload context did not "
        "come back in the new share group (%s)" % (io_ok, LOSSES + 1,
        "; ".join(sorted(set(re.findall(r"io_context ok=0 [^\n]*", log))))))
if "context_robustness when=rebuild" not in log:
    bad("no context_robustness line for the rebuilt context")

# 2. pixels
w, h, ref = ppm(os.path.join(DIR, "ref.ppm"))


def box_px(buf, box):
    x0, y0, bw, bh = box
    for y in range(y0, y0 + bh):
        row = (y * w + x0) * 3
        for x in range(bw):
            o = row + 3 * x
            yield buf[o], buf[o + 1], buf[o + 2]


def content_ok(buf):
    """None when every box shows its content, else what is missing."""
    img = set(box_px(buf, BOXES["image"]))
    if len(img) < 500:
        return "image box has %d colours (no photo)" % len(img)
    txt = sum(1 for r, g, b in box_px(buf, BOXES["text"]) if r > 150 and g > 120)
    if txt < 150:
        return "text box has %d bright px (no text)" % txt
    svg = list(box_px(buf, BOXES["svg"]))
    blue = sum(1 for r, g, b in svg if b > 200 and r < 80)
    red = sum(1 for r, g, b in svg if r > 200 and g < 90 and b < 90)
    if blue < 1000 or red < 500:
        return "svg box blue=%d red=%d (no circle/triangle)" % (blue, red)
    world = list(box_px(buf, BOXES["world"]))
    yellow = sum(1 for r, g, b in world if r > 230 and g > 200 and b < 80)
    terrain = sum(1 for r, g, b in world if 80 <= g <= 140 and 50 <= b <= 70)
    if yellow < 100 or terrain < 5000:
        return "world box sprites=%d terrain=%d px (no world raster/sprites)" % (yellow, terrain)
    return None


why = content_ok(ref)
if why:
    bad("reference frame incomplete before the first loss: %s (fixture not loaded by present %s?)"
        % (why, lost[0][2]))


def diff(buf):
    """(changed px in the frame, {box: changed px})"""
    if len(buf) != len(ref):
        return w * h, {k: -1 for k in BOXES}
    total = 0
    for i in range(0, len(ref), 3):
        if abs(ref[i] - buf[i]) > TOL or abs(ref[i + 1] - buf[i + 1]) > TOL or abs(ref[i + 2] - buf[i + 2]) > TOL:
            total += 1
    per = {}
    for k, box in BOXES.items():
        per[k] = sum(1 for a, b in zip(box_px(ref, box), box_px(buf, box))
                     if max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2])) > TOL)
    return total, per


limit = int(w * h * MAX_OFF)
first_ok = []
for k in range(1, LOSSES + 1):
    ok_at = None
    worst = None
    for j in range(1, 4):
        _, _, buf = ppm(os.path.join(DIR, "loss%d-%d.ppm" % (k, j)))
        total, per = diff(buf)
        if total <= limit:
            if ok_at is None:
                ok_at = j
        elif ok_at is not None:
            bad("loss %d: present %d after the recovery is correct but present %d is not (%s)" % (k, ok_at, j, per))
        else:
            worst = (j, total, per, content_ok(buf))
    if ok_at is None:
        j, total, per, what = worst
        bad("loss %d: none of the 3 presents after the recovery matches the pre-loss frame; present %d: %d px differ %s%s"
            % (k, j, total, per, "; " + what if what else ""))
    first_ok.append(ok_at)

_, _, fin = ppm(os.path.join(DIR, "final.ppm"))
total, per = diff(fin)
if total > limit:
    bad("final frame after %d losses differs from the pre-loss frame: %d px %s" % (LOSSES, total, per))

out = ("%s: OK losses=%d first_correct_present=%s (max %d) final_equal=1 typography_own_rebuilt=%s "
       "max_rebuild_us=%s drop=%s" % (TAG, LOSSES, ",".join(map(str, first_ok)), max(first_ok),
                                      typo.group(2), summ.group(4), "/".join(drops[0])))
print(out)
open(os.path.join(DIR, "check.out"), "w").write(out + "\n")
