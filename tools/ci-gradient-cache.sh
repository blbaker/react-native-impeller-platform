#!/usr/bin/env bash
# ENG-48 gate: two same-size gradient <Svg>s must each paint their OWN picture
# on the per-<Svg> supersample path.
#
# THE BUG. svgSubtreeCacheKey (the per-<Svg> offscreen texture cache key) held
# each path's d, solid colours, opacities, stroke width, matrix and dash, but
# nothing about a url(#id) brush. Two 64x100 Svgs whose rects differ only in
# their gradient got ONE key: the second painted the first one's texture (the
# Mac's pair arm: B red-rising beside A, offscreens=1). The whole-tree
# supersample hides it; it shows once surface px x N passes 8192 on an axis
# (240x2100 at N=4) and each <Svg> goes through its own offscreen.
#
# Fixture: fixtures/eng48-gradient-cache (header lists every app).
#   Part 1 = the Mac's own table (short/alone/sized/pair/swap/mirror/nosuper),
#            asserted on labels + the offscreens= count.
#   Part 2 = per-field arms, asserted per pixel against REFERENCE renders of
#            each Svg alone (no second Svg, so no texture to share): coords,
#            units, offsets, kind, twins (identical content under two ids MUST
#            share), sameid (one id, two defs: one document-wide map, one
#            picture), restop (stops change under the SAME id between frames).
#   Every one-field arm first proves its two pictures DIFFER, or it is vacuous.
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-gradient-cache.sh
# (bash 3.2 safe; python3 stdlib only.)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "GRADIENT_CACHE_GATE_FAIL: $*" >&2; exit 1; }

ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/eng48-gradient-cache"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng48-gradient-cache.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  EXTRA_NPM="react-native-svg@15.15.5" \
    bash "$ROOT/tools/build-fixture-bundle.sh" eng48-gradient-cache pair \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
MEASURE="$ROOT/tools/gradient-cache-measure.py"
N="${GC_N:-4}"         # the per-<Svg> path needs N >= 1; darwin default is 4
TALL="${GC_TALL:-2100}" # 2100 x 4 = 8400 > 8192: the whole-tree hook refuses
TOL="${GC_TOL:-4}"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

render() {  # name app height n [extra engine args...]
  local name="$1" app="$2" h="$3" n="$4" rc nodes ss
  shift 4
  set +e
  "$ENGINE" --bundle "$BUNDLE" --app-name "$app" --headless --width 240 \
    --height "$h" --probe-banner off --supersample-rnsvg "$n" "$@" \
    --screenshot "$WORK/$name.ppm" > "$WORK/$name.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$WORK/$name.log" >&2; fail "$name: headless render exited $rc"; }
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/$name.log" | tail -1)"
  [ -n "$nodes" ] && [ "$nodes" -gt 0 ] || fail "$name: scene_nodes=${nodes:-none}: app '$app' did not mount"
  ss="$(sed -n 's/^rn-impeller: supersample_rnsvg=\([0-9]*\)$/\1/p' "$WORK/$name.log" | tail -1)"
  [ "$ss" = "$n" ] || fail "$name: engine logged supersample_rnsvg=${ss:-none}, want $n (flag did not apply)"
}
offs() { sed -n 's/.*offscreens=\([0-9]*\).*/\1/p' "$WORK/$1.log" | tail -1; }
want_offs() {  # name expected why
  local got
  got="$(offs "$1")"
  [ "$got" = "$2" ] || fail "$1: offscreens=${got:-none}, want $2 ($3)"
}
lab() { python3 "$MEASURE" slot "$WORK/$1.ppm" "$2"; }
want_label() {  # name slot expected
  local got
  got="$(lab "$1" "$2")"
  case "$got" in "$3 "*) ;; *) fail "$1: slot $2 is $got, want $3" ;; esac
}
same() {  # nameA slotA nameB slotB why
  local out
  out="$(python3 "$MEASURE" match "$WORK/$1.ppm" "$2" "$WORK/$3.ppm" "$4" "$TOL")" \
    || fail "$1 slot $2 != $3 slot $4 ($out): $5"
}
differ() {  # nameA slotA nameB slotB why
  local out
  if out="$(python3 "$MEASURE" match "$WORK/$1.ppm" "$2" "$WORK/$3.ppm" "$4" 20)"; then
    fail "$1 slot $2 == $3 slot $4 ($out): $5 -- the arm cannot see the field it tests"
  fi
}
row() {  # name: one summary line in the Mac's format
  printf '   %-8s offscreens=%s P=%s Q=%s\n' "$1" "$(offs "$1")" \
    "$(lab "$1" P | cut -d' ' -f1)" "$(lab "$1" Q | cut -d' ' -f1)"
}

echo "engine $ENGINE (N=$N, tall=$TALL, tol=$TOL)"
echo "== part 1: the Mac's table =="
render short   pair    160   "$N"
render alone   alone-b "$TALL" "$N"
render sized   sized   "$TALL" "$N"
render pair    pair    "$TALL" "$N"
render swap    swap    "$TALL" "$N"
render mirror  mirror  "$TALL" "$N"
render nosuper pair    "$TALL" 0
for r in short alone sized pair swap mirror nosuper; do row "$r"; done
want_label short P red-rising;    want_label short Q blue-falling
want_label alone P blank;         want_label alone Q blue-falling
want_offs  alone 1 "one Svg, one texture"
want_label sized P red-rising;    want_label sized Q blue-falling
want_offs  sized 2 "different sizes, different keys"
want_label pair P red-rising
want_label pair Q blue-falling    # ENG-48: was red-rising (A's picture)
want_offs  pair 2 "two different gradients must rasterise twice"
want_label swap P red-rising;     want_label swap Q blue-falling
want_offs  swap 2 "mount order must not decide whose picture is reused"
want_label mirror P green-rising; want_label mirror Q green-falling
want_offs  mirror 2 "one colour, mirrored opacity: still two pictures"
want_label nosuper P red-rising;  want_label nosuper Q blue-falling
want_offs  nosuper 0 "N=0 paints in place"

echo "== part 2: references (each Svg alone) =="
for ref in ref-P-a ref-Q-b ref-Q-b101 ref-P-ma ref-Q-mb ref-Q-ar ref-P-au \
           ref-Q-ab ref-Q-ao ref-Q-ak ref-Q-a ref-Q-bf; do
  render "$ref" "$ref" "$TALL" "$N"
  want_offs "$ref" 1 "a reference holds one Svg"
done
# The instrument: the same picture in either slot reads the same, so a slot P
# reference can stand for a slot Q render (and the reverse).
same ref-P-a P ref-Q-a Q "the slot must not change the reading"
# Non-vacuity: every one-field arm's two pictures really differ.
differ ref-P-a P ref-Q-b Q "pair"
differ ref-P-ma P ref-Q-mb Q "mirror: opacity-only difference"
differ ref-P-a P ref-Q-ar Q "coords: reversed ramp"
differ ref-P-au P ref-Q-ab Q "units: userSpaceOnUse vs objectBoundingBox"
differ ref-P-a P ref-Q-ao Q "offsets: first stop at 0.5"
differ ref-P-a P ref-Q-ak Q "kind: radial vs linear, same six numbers"
differ ref-Q-a Q ref-Q-bf Q "restop: red-rising vs blue-falling"

echo "== part 2: each Svg paints its own reference =="
same pair P ref-P-a P "pair: A";          same pair Q ref-Q-b Q "pair: B (ENG-48)"
same swap P ref-P-a P "swap: A";          same swap Q ref-Q-b Q "swap: B"
same sized Q ref-Q-b101 Q "sized: B one unit taller"
same mirror P ref-P-ma P "mirror: MA";    same mirror Q ref-Q-mb Q "mirror: MB"
render coords coords "$TALL" "$N"
want_offs coords 2 "gradient coordinates are in the key"
same coords P ref-P-a P "coords: A";      same coords Q ref-Q-ar Q "coords: reversed"
render units units "$TALL" "$N"
want_offs units 2 "gradientUnits is in the key"
same units P ref-P-au P "units: user";    same units Q ref-Q-ab Q "units: bbox"
render offsets offsets "$TALL" "$N"
want_offs offsets 2 "stop offsets are in the key"
same offsets Q ref-Q-ao Q "offsets: first stop at 0.5"
render kind kind "$TALL" "$N"
want_offs kind 2 "linear vs radial is in the key"
same kind Q ref-Q-ak Q "kind: radial"
render twins twins "$TALL" "$N"
want_offs twins 1 "identical content under two ids must SHARE one texture (content key, not id)"
same twins P ref-P-a P "twins: A";        same twins Q ref-Q-a Q "twins: A's content"
render sameid sameid "$TALL" "$N"
want_offs sameid 1 "one id resolves to one gradient document-wide"
same sameid P sameid Q "sameid: both Svgs resolve the one gradient named probe-s"
render restop restop "$TALL" "$N" --frames 8 --screenshot-first "$WORK/restop-first.ppm"
grep -q 'ENG48_RESTOP switch finished=true' "$WORK/restop.log" \
  || fail "restop: the stops never changed during the run (no 'ENG48_RESTOP switch finished=true')"
same restop-first Q ref-Q-a Q "restop: frame 1 must paint the OLD stops, or the arm proves nothing"
same restop Q ref-Q-bf Q "restop: new stops under the SAME id must get a new key"
want_offs restop 2 "old stops, then new stops"
for r in coords units offsets kind twins sameid restop; do row "$r"; done

echo "GRADIENT_CACHE_GATE_PASS (N=$N, tall=$TALL; 7 Mac arms, 7 field arms, 12 references)"
