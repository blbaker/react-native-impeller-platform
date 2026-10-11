"""ci-modal.sh helper: check the SC-29 fixture frame (400x300, see
fixtures/sc29-modal/index.js). Prints MODAL_PIXELS_OK or MODAL_PIXELS_FAIL <why>.
Usage: modal_pixels.py FRAME.ppm transparent|opaque"""
import sys

path, scene = sys.argv[1:3]
data = open(path, "rb").read()
parts = data.split(maxsplit=4)
w, h = int(parts[1]), int(parts[2])
px = parts[4][-w * h * 3:]
GREY, WHITE = (200, 200, 200), (255, 255, 255)
GREEN, RED, BLUE, PURPLE = (0, 255, 0), (255, 0, 0), (0, 0, 255), (128, 0, 128)


def at(x, y):
    i = (y * w + x) * 3
    return tuple(px[i:i + 3])


def near(c, want):
    return all(abs(a - b) <= 6 for a, b in zip(c, want))


app = {"transparent": True, "opaque": False}[scene]
# (point, expected colour, what the point proves)
checks = [
    ((200, 60), GREEN, "green modal box over the later red sibling"),
    ((155, 45), GREEN, "modal box top-left at window (150,40), not shifted by the modal's own frame origin"),
    ((245, 115), GREEN, "modal box bottom-right inside (250,120)"),
    ((255, 60), GREY if app else WHITE, "right of the modal box"),
    ((330, 240), PURPLE, "modal Pressable"),
    ((135, 35), RED if app else WHITE, "later sibling outside the modal box"),
    ((70, 240), BLUE if app else WHITE, "app Pressable under the modal"),
    ((10, 10), GREY if app else WHITE, "window corner"),
    ((390, 290), GREY if app else WHITE, "far window corner"),
]
for (x, y), want, why in checks:
    got = at(x, y)
    if not near(got, want):
        print(f"MODAL_PIXELS_FAIL {scene} ({x},{y}) is {got}, want {want}: {why}")
        sys.exit(1)
print(f"MODAL_PIXELS_OK {scene} ({len(checks)} points)")
