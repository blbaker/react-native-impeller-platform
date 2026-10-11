#!/usr/bin/env bash
# MUTATION VERIFICATION for tools/ci-dev-boot.sh (parity item 12).
#
#   M1  WebSocketModule not registered (pre-fix: dev bundles throw at boot)
#   M2  synchronous connect (pre-fix shape: a never-answered connect to the
#       React DevTools port wedges shutdown)
#   M3  binary frames sent as text (sendBinary type flag dropped)
#   M4  Image placeholder shim removed (LogBox crashes in dev)
set -euo pipefail
cd "$(dirname "$0")/.."
RH="engine/runtime/ReactHost.cpp"
WS="engine/modules/WebSocketModule.cpp"
SH="package/src/metro-shims/index.js"

BAK="$(mktemp -d)"
cp "$RH" "$BAK/ReactHost.cpp"; cp "$WS" "$BAK/WebSocketModule.cpp"; cp "$SH" "$BAK/index.js"
restore() { cp "$BAK/ReactHost.cpp" "$RH"; cp "$BAK/WebSocketModule.cpp" "$WS"; cp "$BAK/index.js" "$SH"; }
trap 'restore; bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || true; echo "logs: $BAK"' EXIT

fail() { echo "MUTATION_VERIFY_FAIL: $*" >&2; exit 1; }

grep -q "// MUTANT" "$RH" "$WS" "$SH" && fail "mutant residue already in the tree -- restore it first (git diff)"
grep -q 'modules_->add("WebSocketModule"' "$RH" || fail "the fix is NOT in the tree -- a passing gate here would be blind"

run_gate() {
  set +e
  bash tools/ci-dev-boot.sh > "$1" 2>&1
  local rc=$?
  set -e
  return $rc
}

mutate() {  # $1 = file, $2 = old text, $3 = new text
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "mutant anchor not found exactly once in %s: %r" % (p, old[:80])
open(p, "w").write(s.replace(old, new, 1))
PY
}

expect_killed() {  # $1 = name, $2 = log, $3 = ERE the FAIL line must carry
  if grep -q DEVBOOT_GATE_PASS "$2"; then
    fail "$1 SURVIVED: the gate passed with this defect"
  fi
  grep -qE "DEVBOOT_GATE_FAIL: .*($3)" "$2" || {
    tail -25 "$2" >&2
    fail "$1 was killed, but not by the expected assertion ('$3'); see the tail above"
  }
  echo "   OK: $1 killed -> $(grep -m1 'DEVBOOT_GATE_FAIL' "$2")"
}

echo "== control: unmutated tree must PASS =="
run_gate "$BAK/control.log" || { tail -40 "$BAK/control.log" >&2; fail "gate fails on the UNMUTATED tree"; }
grep -q DEVBOOT_GATE_PASS "$BAK/control.log" || fail "control did not print DEVBOOT_GATE_PASS"
echo "   OK: control passes"

echo "== M1: WebSocketModule not registered =="
mutate "$RH" \
'  modules_->add("WebSocketModule", [](auto inv) {' \
'  modules_->add("WebSocketModule_MUTANT_M1", [](auto inv) {  // MUTANT M1'
run_gate "$BAK/m1.log" || true
expect_killed M1 "$BAK/m1.log" "a module __DEV__ bundles require is missing|dev bundles do not boot"
restore

echo "== M2: synchronous connect (wedges on a dead port) =="
mutate "$WS" \
'          beast::get_lowest_layer(self->ws).async_connect(
              results, [self, hostHeader, target](beast::error_code ec2,
                                                  tcp::endpoint) {' \
'          // MUTANT M2: blocking connect with no timeout
          beast::error_code mec; tcp::endpoint mep;
          mep = asio::connect(beast::get_lowest_layer(self->ws).socket(), results, mec);
          asio::post(self->ioc, [self, hostHeader, target, mec, mep]() {
              auto cb = [self, hostHeader, target](beast::error_code ec2,
                                                  tcp::endpoint) {'
mutate "$WS" \
'                      self->readNext();
                      self->flush();
                    });
              });
        });' \
'                      self->readNext();
                      self->flush();
                    });
              }; cb(mec, mep); });
        });'
run_gate "$BAK/m2.log" || true
expect_killed M2 "$BAK/m2.log" "wedged shutdown"
restore

echo "== M3: binary frames sent as text =="
mutate "$WS" \
'    ws.binary(outbox.front().binary);' \
'    ws.binary(false);  // MUTANT M3'
run_gate "$BAK/m3.log" || true
expect_killed M3 "$BAK/m3.log" "WebSocket module does not work|sendBinary is broken"
restore

echo "== M4: Image placeholder shim removed =="
mutate "$SH" \
"  'react-native/Libraries/Image/Image.js': 'Image.impeller.js',
};" \
"};  // MUTANT M4"
run_gate "$BAK/m4.log" || true
expect_killed M4 "$BAK/m4.log" "Image placeholder is missing"
restore

echo "MUTATION_VERIFY_DEVBOOT_PASS: control PASS, M1-M4 each FAIL the gate"
