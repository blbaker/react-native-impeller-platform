#!/usr/bin/env bash
# Mutation-verify ci-textinput-inline-os (ENG-01d). Each mutant edits a COPY
# of package/, rebuilds the bundles through tools/build-textinput-inline-os-
# bundles.sh (static scope checks included, in soft mode so the bundles still
# come out), runs the gate on them, and must be killed by the check written
# for it:
#   M1 withImpeller no longer installs the babel-transformer wrapper
#      -> gate A: no TextInput node (the Mac's bug, back)
#   M2 the rename runs at Program EXIT, after babel-preset-expo has inlined
#      Platform.OS -> gate A: no TextInput node (plugin order matters)
#   M3 keepsRuntimePlatform() matches every impeller file, not the TextInput
#      folder -> scope check: rename outside the TextInput folder
#   M4 the resolver hands the as-ios Platform to every importer (the global
#      lie) -> gate B: Platform.OS seen by app code is 'ios'
#   M5 withImpeller stops adding its fingerprint to cacheVersion -> scope
#      check: a cache warmed by the pre-fix shim serves the old TextInput.js
#      (react-native-css's worker has no getCacheKey, so nothing else changes
#      the key)
# The working tree is never edited.
#   TIIOS_APP=<dir>  reuse an installed fixture app (else a fresh npm install)
#   ONLY=M2,M4       run a subset (prints the PARTIAL marker, never the PASS)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="$HOME/.local/bin:$PATH"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="${TIIOS_APP:-$WORK/app}"
IDX="src/metro-shims/index.js"
BT="src/metro-shims/babel-transformer.js"
FAILED=0
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }

mutate() {  # mutate <file-in-package> <old> <new>
  python3 -c '
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(old)
assert n == 1, "anchor found %dx in %s" % (n, p)
open(p, "w").write(s.replace(old, new))' "$PKG/$1" "$2" "$3"
}

run_mutant() {  # run_mutant <id> <killer-ERE> <mutate-fn>
  local id="$1" killer="$2" fn="$3"
  PKG="$WORK/pkg-$id"
  rm -rf "$PKG"; cp -R "$ROOT/package" "$PKG"
  "$fn"
  local out="$WORK/out-$id" log="$WORK/$id.log"
  mkdir -p "$out"
  set +e
  CORE_DIR="$PKG" TIIOS_APP="$APP" TIIOS_SCOPE_SOFT=1 \
    bash "$ROOT/tools/build-textinput-inline-os-bundles.sh" "$out" > "$log" 2>&1
  if grep -q TIIOS_BUILD_FAIL "$log"; then
    echo "  BAD  $id: build failed before the checks ran:"; grep TIIOS_BUILD_FAIL "$log" | head -3
    FAILED=1; set -e; return
  fi
  TIIOS_BUNDLES="$out" bash "$ROOT/tools/ci-textinput-inline-os.sh" >> "$log" 2>&1
  set -e
  local hit; hit="$(grep -m1 -E 'TIIOS_(SCOPE|GATE)_FAIL' "$log" || true)"
  if [ -z "$hit" ]; then
    echo "  BAD  $id SURVIVED (scope + gate both passed)"; FAILED=1
  elif grep -qE "$killer" "$log"; then
    echo "  OK   $id killed: $(grep -m1 -E "$killer" "$log" | cut -c1-150)"
  else
    echo "  BAD  $id killed, but not by its own check: $hit"; FAILED=1
  fi
}

m1() { mutate "$IDX" "  if (!current) return config;" "  return config;"; }
m2() { mutate "$BT" "      Program(programPath) {" "      Program: {exit(programPath) {"
       mutate "$BT" "        programPath.scope.rename('Platform', programPath.scope.generateUid('rniRuntimePlatform'));
      },
    },"  "        programPath.scope.rename('Platform', programPath.scope.generateUid('rniRuntimePlatform'));
      }},
    },"; }
m3() { mutate "$IDX" "  if (platform !== 'impeller' || !filename) return false;
  const posix = toPosix(filename);" "  if (platform !== 'impeller' || !filename) return false;
  return true;
  const posix = toPosix(filename);"; }
m4() { mutate "$IDX" "  if (!toPosix(resolvedFilePath).endsWith(PLATFORM_MODULE_SUFFIX)) return null;
  const origin = toPosix(originModulePath);" "  if (!toPosix(resolvedFilePath).endsWith(PLATFORM_MODULE_SUFFIX)) return null;
  if (!/Platform\\.impeller(-as-ios)?\\.js\$/.test(originModulePath)) return path.join(SHIM_DIR, 'Platform.impeller-as-ios.js');
  const origin = toPosix(originModulePath);"; }

m5() { mutate "$IDX" "    cacheVersion: [config.cacheVersion, 'react-native-impeller:' + runtimePlatformFingerprint()]
      .filter(Boolean)
      .join(':')," "    cacheVersion: config.cacheVersion,"; }

echo "== ENG-01d TextInput inline-OS: mutation verification =="
want M1 && run_mutant M1 'TIIOS_GATE_FAIL: A: expected 3 TextInput nodes' m1
want M2 && run_mutant M2 'TIIOS_GATE_FAIL: A: expected 3 TextInput nodes' m2
want M3 && run_mutant M3 'TIIOS_SCOPE_FAIL.*outside the TextInput folder' m3
want M4 && run_mutant M4 "TIIOS_GATE_FAIL: B: Platform.OS must stay 'impeller'" m4
want M5 && run_mutant M5 'TIIOS_SCOPE_FAIL\(warm-cache\): _rniRuntimePlatform missing from TextInput.js' m5

if [ "$FAILED" != 0 ]; then echo "TIIOS_MUTATION_FAIL"; exit 1; fi
if [ -n "${ONLY:-}" ]; then echo "TIIOS_MUTATION_PARTIAL_PASS ($ONLY)"; else echo "TIIOS_MUTATION_PASS"; fi
