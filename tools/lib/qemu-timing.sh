# qemu-timing.sh: one switch for gates whose fixed timeouts or clock anchors
# assume a native CPU. Source it, then:
#   rni_is_qemu            true when the engine runs under qemu-aarch64 user
#                          emulation: RNI_QEMU=1, or RNI_BIN is the
#                          tools/arm64-run-engine.sh wrapper
#   rni_qemu_relax <what>  print the relaxation, so the gate output says so
#
# Why (M3 triage, 2026-10-19, docs/IMAGE-REQUIREMENTS.md "M3 as built"): the same
# first-present fixture measured process start -> first present 36967 ms on
# the arm64 package under qemu against 258 ms on x64 natively (143x), and JS
# start -> first rAF tick 550 ms against 48 ms (11x). Gates with a 30 s wait for
# the first present, or a clock anchored at JS start, fail a correct engine
# there. A relaxed gate is evidence of behaviour, never of speed: frame times
# measured under qemu are UNVERIFIED-ON-HARDWARE.
rni_is_qemu() {
  [ "${RNI_QEMU:-0}" = 1 ] && return 0
  case "${RNI_BIN:-}" in */arm64-run-engine.sh) return 0 ;; esac
  return 1
}
rni_qemu_relax() { echo "QEMU_TIMING_RELAXED: $*"; }
