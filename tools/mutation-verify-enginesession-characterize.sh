#!/usr/bin/env bash
# Mutation check for tools/enginesession-normalize.sh/.sed, the filter
# tools/ci-enginesession-characterize.sh diffs through. Fast and
# ci-all.sh-free: two synthetic fixture pairs, not a real engine run.
#
#   noise_before/after: differ ONLY in fields the normalizer is supposed to
#     erase (a tmp path, a port, two timings). Must compare EQUAL.
#   real_diff_before/after: differ in an asserted PIXEL VALUE (a gate's
#     actual subject). Must compare DIFFERENT.
#
# Mutant: make the normalizer swallow digits generally, not just the named
# dynamic fields. The noise case still passes (digits are still erased),
# but the real-difference case now ALSO compares equal -- exactly the
# failure mode that would hide a genuine regression behind this gate's own
# PASS line. The control-then-mutant order matters: if the real-difference
# fixture could not fail on the unmutated normalizer, a later "still passes"
# would prove nothing (see control below).
set -euo pipefail
cd "$(dirname "$0")/.."

SED=tools/enginesession-normalize.sed
BAK="$(mktemp -d)"
cp "$SED" "$BAK/enginesession-normalize.sed.orig"
restore() { cp "$BAK/enginesession-normalize.sed.orig" "$SED"; rm -rf "$BAK"; }
trap restore EXIT
fail() { echo "ENGINESESSION_CHARACTERIZE_MUTATION_FAIL: $*" >&2; exit 1; }

cat > "$BAK/noise_before.log" <<'EOF'
### gate 3/6: pack and consume (P1)
   rn-impeller: screenshot=/build/tmp.aB3dEfGhIj/frame.ppm
   OK plain fill @70,50 rgb=255,0,0
### gate 16c: first present lands inside a launch animation
   OK: first frame heard 63 ms after JS start (< 1500); process start -> present 261 ms
FIRST_PRESENT_GATE_PASS (js_ms=63 first_present_ms=261 bg=ff0000 mark_x=0)
P10_NETWORKING_PASS (nodes=10 painted=10 port=36989)
EOF
cat > "$BAK/noise_after.log" <<'EOF'
### gate 3/6: pack and consume (P1)
   rn-impeller: screenshot=/build/tmp.ZZ9kLmNoPq/frame.ppm
   OK plain fill @70,50 rgb=255,0,0
### gate 16c: first present lands inside a launch animation
   OK: first frame heard 71 ms after JS start (< 1500); process start -> present 305 ms
FIRST_PRESENT_GATE_PASS (js_ms=71 first_present_ms=305 bg=ff0000 mark_x=0)
P10_NETWORKING_PASS (nodes=10 painted=10 port=41222)
EOF
cat > "$BAK/real_diff_before.log" <<'EOF'
   OK plain fill @70,50 rgb=255,0,0
EOF
cat > "$BAK/real_diff_after.log" <<'EOF'
   OK plain fill @70,50 rgb=0,255,0
EOF

compare() {  # compare FILE1 FILE2 -> 0 if equal after normalization
  diff -q \
    <(bash tools/enginesession-normalize.sh < "$1") \
    <(bash tools/enginesession-normalize.sh < "$2") > /dev/null
}

echo "== control: unmutated normalizer =="
compare "$BAK/noise_before.log" "$BAK/noise_after.log" \
  || fail "control: noise-only fixtures compared DIFFERENT (normalizer too weak, or a fixture typo)"
echo "   OK: noise-only fixtures compare EQUAL"
if compare "$BAK/real_diff_before.log" "$BAK/real_diff_after.log"; then
  fail "control: the real-difference fixture already compares EQUAL on the unmutated normalizer -- it cannot prove the mutant below changed anything"
fi
echo "   OK: the real pixel difference compares DIFFERENT"

echo "== mutant: normalizer erases ALL digits, not just the named fields =="
cat >> "$SED" <<'SED'
s/[0-9]+/<N>/g
SED
if ! compare "$BAK/real_diff_before.log" "$BAK/real_diff_after.log"; then
  fail "SURVIVED: the over-eager normalizer still reports the real pixel difference as DIFFERENT"
fi
echo "   OK: mutant killed -- the real difference (rgb=255,0,0 vs rgb=0,255,0) now reads as EQUAL"
restore
trap - EXIT

echo "ENGINESESSION_CHARACTERIZE_MUTATION_PASS (1/1 mutant killed by its own assertion)"
