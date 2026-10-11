#!/usr/bin/env bash
# mutation-verify-expo-host — prove tools/ci-expo-host.sh can FAIL.
#
# Each mutant reverts or breaks one piece of the Expo host, rebuilds the
# engine, and requires the gate to fail with THAT mutant's own assertion.
# A survivor, or a kill by an unrelated assertion, fails this script.
# Run it as a systemd unit or similar: it edits the live tree (restored on
# exit) and rebuilds the shared staged binary once per mutant.
#   ONLY=M3,M8 bash tools/mutation-verify-expo-host.sh   (subset; prints PARTIAL)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"
HOST=engine/modules/ExpoHost.cpp; HASH=engine/modules/ExpoHash.h; RH=engine/runtime/ReactHost.cpp
BAK="$(mktemp -d)"
cp "$HOST" "$BAK/ExpoHost.cpp"; cp "$HASH" "$BAK/ExpoHash.h"; cp "$RH" "$BAK/ReactHost.cpp"
put_back() { cp "$BAK/ExpoHost.cpp" "$HOST"; cp "$BAK/ExpoHash.h" "$HASH"; cp "$BAK/ReactHost.cpp" "$RH"; }
restore() {
  put_back
  bash tools/engine-build.sh > /dev/null 2>&1 || echo "WARN: rebuild of restored tree failed" >&2
  rm -rf "$BAK"
}
[ -n "${DRY:-}" ] && trap 'put_back; rm -rf "$BAK"' EXIT || trap restore EXIT
fail() { echo "EXPO_HOST_MUTATION_FAIL: $*" >&2; exit 1; }
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }
run_gate() { set +e; bash tools/ci-expo-host.sh > "$1" 2>&1; local rc=$?; set -e; return $rc; }
mutate() {  # file old new  (old must occur exactly once)
  python3 "$(dirname "$0")/expo_mutate.py" "$1" "$2" "$3" ${DRY:+--dry} || fail "anchor not found: $2"
}
KILLED=0
check() {  # name expected-failure-substring
  if [ -n "${DRY:-}" ]; then
    grep -qF -- "$(echo "$2" | sed -E "s/^check '([^']*)' did not PASS$/\1/")" tools/ci-expo-host.sh fixtures/expo-host/contract.js \
      || echo "   WARN: $1 expectation text not found in gate/fixture: $2"
    echo "   dry: $1 anchor ok"; KILLED=$((KILLED + 1)); return; fi
  bash tools/engine-build.sh > "$BAK/$1.build.log" 2>&1 || { tail -15 "$BAK/$1.build.log" >&2; fail "$1 tree did not build"; }
  if run_gate "$BAK/$1.log"; then fail "$1 SURVIVED: gate passed with the mutant in"; fi
  grep -qF -- "$2" "$BAK/$1.log" || { tail -6 "$BAK/$1.log" >&2; fail "$1 killed by the WRONG assertion (wanted: $2)"; }
  echo "   OK: $1 killed ($(grep -o 'EXPO_HOST_GATE_FAIL: .*' "$BAK/$1.log" | cut -c1-120))"
  KILLED=$((KILLED + 1))
  put_back
}

echo "== control: unmutated tree must PASS =="
[ -n "${DRY:-}" ] && echo "   dry run: anchors only" || {
bash tools/engine-build.sh > "$BAK/control.build.log" 2>&1 || fail "control tree did not build"
run_gate "$BAK/control.log" || { tail -8 "$BAK/control.log" >&2; fail "control FAILED: nothing below means anything"; }
echo "   OK: control passes"; }

if want M1; then echo "== M1: globalThis.expo never installed =="
mutate "$RH" "        installExpoGlobal(runtime, expo, jsInvoker, expoConfig);" "        (void)expo; (void)expoConfig;"
check M1 "EventEmitter' of undefined"; fi

if want M2; then echo "== M2: ExpoAsset not registered =="
mutate "$HOST" '  registry.add("ExpoAsset", std::move(asset));' '  (void)registry; (void)asset;'
check M2 "Cannot find native module 'ExpoAsset'"; fi

if want M3; then echo "== M3: uuidv5 stamps version 4 =="
mutate "$HOST" "  b[6] = static_cast<uint8_t>((b[6] & 0x0f) | 0x50);" "  b[6] = static_cast<uint8_t>((b[6] & 0x0f) | 0x40);"
check M3 "check 'uuidv5-shape' did not PASS"; fi

if want M4; then echo "== M4: a throwing listener stops emit =="
mutate "$HOST" "      try { listener.apply(undefined, args); } catch (e) { console.error(e); }" "      listener.apply(undefined, args);"
check M4 "check 'emitter' did not PASS"; fi

if want M5; then echo "== M5: startObserving on every addListener =="
mutate "$HOST" "    if (before === 0 && set.size === 1) this.startObserving(eventName);" "    this.startObserving(eventName);"
check M5 "check 'emitter' did not PASS"; fi

if want M6; then echo "== M6: cached asset reused without checking its MD5 =="
mutate "$HOST" "        (md5Hash.empty() || expohash::md5Hex(existing) == md5Hash)) {" "        true) {"
check M6 "case e: stale cache file was not refetched"; fi

if want M7; then echo "== M7: MD5 round constants off (ceil for floor) =="
mutate "$HASH" "          std::floor(std::fabs(std::sin(static_cast<double>(i + 1))) * 4294967296.0));" "          std::ceil(std::fabs(std::sin(static_cast<double>(i + 1))) * 4294967296.0));"
check M7 "check 'dl-c-cache-hit' did not PASS"; fi

if want M8; then echo "== M8: SHA-1 rotate 29 for 30 =="
mutate "$HASH" "      c = rotl32(b, 30);" "      c = rotl32(b, 29);"
check M8 "Python's uuid5"; fi

if want M9; then echo "== M9: an ExpoGo module is vended =="
mutate "$HOST" '  registry.add("ExpoAsset", std::move(asset));' '  registry.add("ExpoAsset", std::move(asset));
  registry.add("ExpoGo", ExpoModuleDef{});'
check M9 "check 'expo-go-absent' did not PASS"; fi

if want M10; then echo "== M10: settle drops the value =="
mutate "$HOST" "                              jsi::valueFromDynamic(rt, value));" "                              jsi::Value::undefined());"
check M10 "check 'dl-a-no-md5' did not PASS"; fi

if want M11; then echo "== M11: download resolves the REMOTE url, not the cache file =="
mutate "$HOST" "    } else {
      settle(true, fileUrl(local));
    }
    done();" "    } else {
      settle(true, url);
    }
    done();"
check M11 "check 'dl-a-no-md5' did not PASS"; fi

if want M12; then echo "== M12: '/' allowed in an asset file name =="
mutate "$HOST" "                    (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
    if (!ok) return false;" "                    (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_' || c == '/';
    if (!ok) return false;"
check M12 "check 'dl-g-rejects-escape' did not PASS"; fi

if [ -n "${DRY:-}" ]; then echo "EXPO_HOST_MUTATION_DRY_OK ($KILLED anchors found, nothing built)"; exit 0; fi
if [ -n "${ONLY:-}" ]; then echo "EXPO_HOST_MUTATION_PARTIAL_PASS ($KILLED killed: $ONLY)"; exit 0; fi
[ "$KILLED" -eq 12 ] || fail "only $KILLED/12 mutants ran"
echo "EXPO_HOST_MUTATION_PASS (12/12 mutants killed by their own assertion)"
