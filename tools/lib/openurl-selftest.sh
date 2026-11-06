# The URL predicate self-test (`rn-impeller --test-openurl`), shared by the P4 gate.
#
# The verdict is matched as a LINE, not as the start of stdout: the engine prints
# its startup diagnostics (malloc policy, mem trim, PSI memory pressure) to stdout
# before it parses its flags, so the verdict follows them. A failing case prints
# OPENURL_FAIL and exits 1 (engine/modules/PlatformModules.cpp).
#   rni_openurl_selftest ENGINE   prints the OPENURL_PASS line, or why not and returns 1
rni_openurl_selftest() {
  local out
  out="$("$1" --test-openurl)" || { printf 'exited nonzero: %s\n' "$out"; return 1; }
  printf '%s\n' "$out" | grep -m1 '^OPENURL_PASS ' && return 0
  printf 'did not pass: %s\n' "$out"
  return 1
}
