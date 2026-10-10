#!/usr/bin/env bash
# SC-32 GATE: the custom Impeller SDK (tools/impeller-sdk-custom-build.sh).
# Rules, in order (the FAIL line names the first that breaks):
#   stamp        built from engine/IMPELLER_SHA + the committed patches
#   header       IMPELLER_RNI_TEXT_EXTENSIONS and the 7 new declarations
#   exports      libimpeller.so exports the 7 new symbols AND every stock one
#   letterSpacing  'IIII' + 8 px letter spacing is 4*8 px wider
#   wordSpacing    'a b c' + 10 px word spacing is 2*10 px wider
#   fontFeature    tnum makes '1111' as wide as '0000', pnum does not; smcp
#                  changes 'abc' width; ClearFontFeatures and a bad tag are no-ops
#   placeholder    one 14x14 box between 'AB' and 'CD', 'CD' pushed 14 px
#   placeholderAlign  baseline puts the box 10 px above the baseline, top at the line top
#   cmake        engine/build selects the custom SDK and the staged
#                libimpeller.so is the custom one (linux default dir only)
# The probe (tools/impeller-sdk-probe.c) lays text out on the CPU, no GPU.
#   bash tools/ci-impeller-sdk-custom.sh [--all-platforms]
# Env: RNI_IMPELLER_SDK_DIR  SDK to judge (default engine/third_party/impeller-sdk-custom)
#      RNI_SDK_STAMP_PATCH  patch file the stamp must name (mutants)
#      RNI_SDK_PROBE_FONT   font with tnum/pnum/smcp (default FreeSans)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "IMPELLER_SDK_CUSTOM_GATE_FAIL: $*"; exit 1; }
ok() { echo "   ok: $*"; }
DEFAULT_SDK=engine/third_party/impeller-sdk-custom
SDK="${RNI_IMPELLER_SDK_DIR:-$DEFAULT_SDK}"
FONT="${RNI_SDK_PROBE_FONT:-/usr/share/fonts/truetype/freefont/FreeSans.ttf}"
SHA="$(tr -d ' \n' < engine/IMPELLER_SHA)"
NEW_SYMS="ImpellerParagraphStyleSetLetterSpacing ImpellerParagraphStyleSetWordSpacing
ImpellerParagraphStyleSetFontFeature ImpellerParagraphStyleClearFontFeatures
ImpellerParagraphBuilderAddPlaceholder ImpellerParagraphGetPlaceholderRects"
STOCK_H=engine/third_party/impeller-sdk/include/impeller.h

check_header() {  # dir
  local h="$1/include/impeller.h"
  [ -f "$h" ] || fail "header: no $h (run tools/impeller-sdk-custom-build.sh)"
  grep -q '^#define IMPELLER_RNI_TEXT_EXTENSIONS 1' "$h" || fail "header: IMPELLER_RNI_TEXT_EXTENSIONS missing in $h"
  for s in $NEW_SYMS kImpellerPlaceholderAlignmentMiddle; do
    grep -q "\b$s\b" "$h" || fail "header: $s not declared in $h"
  done
}
check_stamp() {  # dir
  local st="$1/.stamp" want
  if [ -n "${RNI_SDK_STAMP_PATCH:-}" ]; then want="$(sha256sum < "$RNI_SDK_STAMP_PATCH" | cut -c1-64)"
  else want="$(cat engine/impeller-sdk-patches/*.patch | sha256sum | cut -c1-64)"; fi
  [ -f "$st" ] || fail "stamp: no $st"
  grep -qx "sha=$SHA" "$st" || fail "stamp: $st is not built from engine/IMPELLER_SHA $SHA"
  grep -qx "patch_sha256=$want" "$st" || fail "stamp: $st was built from other patches (rebuild the SDK)"
}

if [ "${1:-}" = --all-platforms ]; then
  # SC-35: every desktop target has its custom SDK. Their probes run on their
  # own hosts; here the layout, stamp and header are judged.
  for d in "$DEFAULT_SDK" engine/third_party/impeller-sdk-custom-darwin engine/third_party/impeller-sdk-custom-win; do
    [ -d "$d" ] || fail "all-platforms: $d missing"
    check_stamp "$d"; check_header "$d"; ok "$d"
  done
fi

echo "== custom SDK $SDK =="
check_stamp "$SDK"; ok "stamp"
check_header "$SDK"; ok "header"

LIB="$SDK/lib/libimpeller.so"
[ -f "$LIB" ] || fail "exports: no $LIB"
EXP="$(readelf --dyn-syms -W "$LIB" | awk '$5=="GLOBAL" && $7!="UND" {print $8}' | grep '^Impeller' | sort -u)"
for s in $NEW_SYMS; do echo "$EXP" | grep -qx "$s" || fail "exports: $s not exported by $LIB"; done
STOCK_EXP="$(readelf --dyn-syms -W engine/third_party/impeller-sdk/lib/libimpeller.so | awk '$5=="GLOBAL" && $7!="UND" {print $8}' | grep '^Impeller' | sort -u)"
missing="$(comm -23 <(echo "$STOCK_EXP") <(echo "$EXP") | head -3)"
[ -z "$missing" ] || fail "exports: stock symbols missing from the custom SDK: $missing"
ok "exports ($(echo "$EXP" | wc -l) symbols, stock $(echo "$STOCK_EXP" | wc -l))"
[ -f "$STOCK_H" ] && ! grep -q IMPELLER_RNI_TEXT_EXTENSIONS "$STOCK_H" || fail "header: the stock SDK header was overwritten"

[ -f "$FONT" ] || fail "probe font $FONT missing (apt install fonts-freefont-ttf, or set RNI_SDK_PROBE_FONT)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cc -std=c11 -O1 -I"$SDK/include" tools/impeller-sdk-probe.c -o "$WORK/probe" \
   "$(cd "$SDK/lib" && pwd)/libimpeller.so" -Wl,-rpath,"$(cd "$SDK/lib" && pwd)" > "$WORK/cc.log" 2>&1 \
  || { tail -5 "$WORK/cc.log"; fail "probe: does not compile against $SDK"; }
"$WORK/probe" "$FONT" > "$WORK/probe.txt" 2> "$WORK/probe.err" || { tail -5 "$WORK/probe.err"; fail "probe: crashed"; }
grep -q PROBE_DONE "$WORK/probe.txt" || fail "probe: incomplete output"
sed 's/^/   /' "$WORK/probe.txt" | grep -v PROBE_DONE | paste -sd' ' | fold -s -w 160

python3 - "$WORK/probe.txt" <<'PY' || exit 1
import sys
v = {}
for line in open(sys.argv[1]):
    if "=" in line:
        k, x = line.strip().split("=", 1); v[k] = float(x)
def rule(name, cond, why):
    if not cond:
        print(f"IMPELLER_SDK_CUSTOM_GATE_FAIL: {name}: {why}"); sys.exit(1)
    print(f"   ok: {name}")
d = v["iiii_ls8"] - v["iiii_ls0"]
rule("letterSpacing", abs(d - 32) <= 1, f"'IIII' widened {d:.2f} px with letterSpacing 8, want 32 +/- 1")
d = v["words_ws10"] - v["words_ws0"]
rule("wordSpacing", abs(d - 20) <= 1, f"'a b c' widened {d:.2f} px with wordSpacing 10, want 20 +/- 1")
t = abs(v["n1111_tnum"] - v["n0000_tnum"]); p = v["n0000_pnum"] - v["n1111_pnum"]
s = v["abc_smcp"] - v["abc"]
rule("fontFeature", t <= 0.5 and p >= 2 and abs(s) >= 2
     and abs(v["abc_cleared"] - v["abc"]) <= 0.01 and abs(v["abc_badtag"] - v["abc"]) <= 0.01,
     f"tnum |1111-0000|={t:.2f} (<=0.5), pnum 0000-1111={p:.2f} (>=2), smcp width change={s:.2f} (|.|>=2), "
     f"cleared {v['abc_cleared']:.2f} / bad tag {v['abc_badtag']:.2f} vs plain {v['abc']:.2f}")
b = "ph_base"
rule("placeholder", v[b+"_count"] == 1 and v[b+"_count_null"] == 1
     and abs(v[b+"_w"] - 14) <= 0.01 and abs(v[b+"_h"] - 14) <= 0.01
     and abs(v[b+"_x"] - v["ab"]) <= 0.5 and abs(v[b+"_width"] - v["abcd"] - 14) <= 0.5,
     f"count {v[b+'_count']:.0f}/{v[b+'_count_null']:.0f} (1), box x {v[b+'_x']:.2f} (AB ends {v['ab']:.2f}) "
     f"{v[b+'_w']:.2f}x{v[b+'_h']:.2f} (14x14), width {v[b+'_width']:.2f} vs ABCD {v['abcd']:.2f} + 14")
rule("placeholderAlign", abs(v[b+"_y"] + 10 - v[b+"_baseline"]) <= 0.5 and 0 <= v["ph_top_y"] <= 1.5,
     f"baseline box y {v[b+'_y']:.2f} + 10 vs baseline {v[b+'_baseline']:.2f}; top box y {v['ph_top_y']:.2f} (0..1.5)")
PY

if [ "$SDK" = "$DEFAULT_SDK" ]; then
  CACHE=engine/build/CMakeCache.txt
  got="$(grep '^IMPELLER_SDK:PATH=' "$CACHE" 2>/dev/null | cut -d= -f2-)"
  [ "$got" = "$ROOT/$DEFAULT_SDK" ] || fail "cmake: engine/build uses IMPELLER_SDK=$got, not $ROOT/$DEFAULT_SDK (run tools/engine-build.sh linux x64)"
  STAGED=packages-engine/engine-linux-x64/bin/libimpeller.so
  [ "$(sha256sum < "$STAGED")" = "$(sha256sum < "$LIB")" ] || fail "cmake: staged $STAGED is not the custom SDK's libimpeller.so"
  ok "cmake (engine/build + staged lib use the custom SDK)"
fi
echo "IMPELLER_SDK_CUSTOM_GATE_PASS"
