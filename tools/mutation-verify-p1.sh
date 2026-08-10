#!/usr/bin/env bash
# Mutation-verify the P1 consumer gate. A gate nobody has watched FAIL is decoration.
#
# Each mutant breaks ONE link in the packaging chain; the gate must go red, and the
# failure message must name that link. Baseline must be green first.
#
#   M1  drop the shims from package.json "files"   -> layer 1 (tarball contents)
#   M2  neuter withImpeller (return config as-is)  -> layer 2 (marker in bundle)
#   M3  hardcode the app name in the scaffold      -> D5 scaffold-not-hardcode
#   M4  engine paints the swatch unconditionally   -> layer 3 (pixels must be evidence)
#
# Every mutation is applied to a COPY of the repo, never to the working tree.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD"
: "${BASE_APP:=$HOME/.cache/rni/base}"
export BASE_APP

run_case() {  # name expect_pass mutate_fn
  local name="$1" expect="$2" fn="$3"
  local work; work="$(mktemp -d)"
  cp -r "$SRC/package" "$SRC/tools" "$SRC/engine" "$SRC/packages-engine" "$work/" 2>/dev/null
  mkdir -p "$work/docs" && : > "$work/docs/.keep"
  ( cd "$work" && "$fn" )
  local log="$work/gate.log" rc=0
  ( cd "$work" && bash tools/pack-and-consume.sh ) > "$log" 2>&1 || rc=$?
  local got="FAIL"; grep -q PACK_AND_CONSUME_PASS "$log" && got="PASS"
  local why; why="$(grep -m1 PACK_AND_CONSUME_FAIL "$log" || true)"
  if [ "$got" = "$expect" ]; then
    printf '  %-4s %-46s %s  %s\n' "OK" "$name" "$got" "${why#PACK_AND_CONSUME_FAIL: }"
    rm -rf "$work"
  else
    printf '  %-4s %-46s expected %s got %s\n' "BAD" "$name" "$expect" "$got"
    echo "     log: $log"; tail -20 "$log" | sed 's/^/     /'
    FAILED=1
  fi
}

baseline() { bash tools/engine-build.sh linux x64 >/dev/null; }

m1_drop_shims_from_files() {
  baseline
  node -e '
    const fs=require("fs"), p="package/package.json";
    const j=JSON.parse(fs.readFileSync(p,"utf8"));
    j.files=j.files.filter(f=>f!=="src").concat(["src/cli","src/resolve.js","src/index.js","src/bin"]);
    fs.writeFileSync(p, JSON.stringify(j,null,2));'
}

m2_neuter_metro_plugin() {
  baseline
  cat > package/src/metro-shims/index.js <<'JS'
'use strict';
function withImpeller(config = {}) { return config; }   // MUTANT: does nothing
module.exports = {withImpeller};
JS
}

m3_hardcode_app_name() {
  baseline
  node -e '
    const fs=require("fs"), p="package/src/cli/init.js";
    let s=fs.readFileSync(p,"utf8");
    s=s.replace("const appName = detectAppName(root);","const appName = \"playground\";");
    fs.writeFileSync(p,s);'
}

m4_swatch_always_green() {
  # Engine lies: it paints green without checking. The bundle marker is ALSO mutated,
  # so this mutant proves the grep layer catches a broken shim even when the engine
  # reports success. (It is caught at layer 2 by design — see M5 for the pixel-only case.)
  sed -i 's/const bool shim_ok = bundle.find(kShimMarker) != std::string::npos;/const bool shim_ok = true;  \/\/ MUTANT/' engine/host/main.cpp
  bash tools/engine-build.sh linux x64 >/dev/null
  node -e '
    const fs=require("fs"), p="package/src/metro-shims/shims/Platform.impeller.js";
    let s=fs.readFileSync(p,"utf8");
    s=s.replace(/__RN_IMPELLER_SHIM_V1__/g,"__RN_IMPELLER_SHIM_MUTATED__");
    fs.writeFileSync(p,s);'
}

m5_engine_draws_nothing() {
  # PIXEL-ONLY mutant: packaging is perfectly intact -- tarball complete, shim resolved,
  # marker in the bundle, engine exits 0 and prints RENDER_OK -- but the frame is blank.
  # Nothing except the pixel assertions can catch this. It is the whole reason the gate
  # reads the framebuffer instead of trusting an exit code.
  sed -i 's/CHECK(ImpellerSurfaceDrawDisplayList(surface, dl), "SurfaceDrawDisplayList returned false");/\/\/ MUTANT: draw call removed/' engine/host/main.cpp
  bash tools/engine-build.sh linux x64 >/dev/null
}


FAILED=0
echo "== baseline =="
run_case "baseline (unmutated)" PASS baseline
echo "== mutants (each must turn the gate RED) =="
run_case "M1 shims dropped from package files" FAIL m1_drop_shims_from_files
run_case "M2 withImpeller neutered"            FAIL m2_neuter_metro_plugin
run_case "M3 scaffold hardcodes app name"      FAIL m3_hardcode_app_name
run_case "M4 engine paints green regardless"   FAIL m4_swatch_always_green
run_case "M5 engine draws nothing (pixel-only)" FAIL m5_engine_draws_nothing

[ "$FAILED" = "0" ] && echo "MUTATION_VERIFY_PASS" || { echo "MUTATION_VERIFY_FAIL"; exit 1; }
