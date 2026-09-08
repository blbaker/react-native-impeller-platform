#!/usr/bin/env bash
# MUTATION VERIFICATION for the P10 networking gate.
#
# A gate that has never been seen RED is a hypothesis. This breaks networking
# in eight specific ways and requires tools/ci-p10.sh to fail on each, then
# restores the tree and requires it to pass again.
#
# ⛔ THE SHAPE THAT MATTERS HERE: EVERY MUTANT BELOW LEAVES THE APP LOOKING
# COMPLETELY HEALTHY. No exception is thrown, no node fails to mount, every
# pixel that is not a networking probe paints correctly, and the process exits
# 0. RN's JS half of networking is complete without any native module —
# whatwg-fetch installs a real global `fetch` — so `typeof fetch === 'function'`
# is TRUE under M1, which removes the native module entirely. A gate checking
# that would call M1 green.
#
# M6, M7 and M8 are the three defects THIS PHASE ACTUALLY SHIPPED and had to
# fix after the gate caught them (measured, not imagined):
#   M6  responseType ignored     -> "Invalid string. Length must be a multiple of 4"
#   M7  chunked framing ignored  -> JS received "13\r\n" as the response body
#   M8  connect not bounded      -> a request hung past the settle, in_flight=1
# They are kept as mutants because a regression in any of them is silent.
#
# THE MUTANT MUST ACTUALLY APPLY. Every patch asserts its pattern is present;
# a mutation script whose pattern has drifted leaves the tree UNMUTATED, the
# gate correctly goes green, and the run reports the mutant as UNCAUGHT —
# sending you to debug a gate that is fine.
set -euo pipefail
cd "$(dirname "$0")/.."

REG="engine/runtime/ReactHost.cpp"
NET="engine/modules/NetworkingModule.cpp"
MAIN="engine/host/main.cpp"
SHIM="package/src/metro-shims/index.js"

BACKUP="$(mktemp -d)"
for f in "$REG" "$NET" "$MAIN" "$SHIM"; do
  cp "$f" "$BACKUP/$(basename "$f")"
done
restore_files_only() {
  for f in "$REG" "$NET" "$MAIN" "$SHIM"; do
    cp "$BACKUP/$(basename "$f")" "$f"
  done
}
trap 'restore_files_only; rm -rf "$BACKUP"' EXIT

PASSED=0
FAILED=0

# mutate <file> <find> <replace> — fails loudly if <find> is not present.
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, find, repl = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if find not in s:
    sys.stderr.write("MUTANT DID NOT APPLY — pattern not found in %s:\n%s\n" % (path, find))
    sys.exit(1)
open(path, "w").write(s.replace(find, repl, 1))
PY
}

expect_red() {
  local name="$1"
  echo "--- mutant: $name"
  if bash tools/ci-p10.sh > "$BACKUP/out.log" 2>&1; then
    echo "    ❌ GATE STAYED GREEN — it does not detect: $name"
    FAILED=$((FAILED + 1))
  else
    echo "    ✅ RED: $(grep -m1 -A2 'P10_NETWORKING_FAIL' "$BACKUP/out.log" | tail -1 | head -c 200)"
    PASSED=$((PASSED + 1))
  fi
  restore_files_only
}

echo "=== baseline must be GREEN before any mutant means anything ==="
bash tools/ci-p10.sh > "$BACKUP/base.log" 2>&1 \
  || { echo "BASELINE IS RED — fix that first:"; tail -20 "$BACKUP/base.log"; exit 1; }
echo "    ✅ baseline green"

# M1 — THE ORIGINAL DEFECT, restored. The Networking module is not registered
# at all. `fetch` remains a function, the bundle runs, every node paints, and
# nothing throws. This is the state the engine shipped in for its entire life,
# and it is why the fixture asserts TurboModuleRegistry.get('Networking')
# separately from any fetch-shaped check.
mutate "$REG" \
  '  modules_->add("Networking", [n = network_](auto inv) {
    return std::make_shared<NetworkingModule>(inv, n);
  });' \
  '  // MUTANT: Networking not registered'
expect_red "M1 Networking module dropped from the registry (fetch stays a function)"

# M2 — the ios-stub disease aimed at networking. The NATIVE module stays
# perfect and registered; the JS simply never reaches it, because
# RCTNetworking.js resolves to a self-referencing re-export on this platform.
# This is the LAYER 3 failure ci-p4.sh warns about, and it proves the gate
# checks the INSTALLED shim rather than the repo's copy.
mutate "$SHIM" \
  "  'react-native/Libraries/Network/RCTNetworking.js': 'RCTNetworking.ios.js'," \
  "  // MUTANT: RCTNetworking self-resolves"
expect_red "M2 RCTNetworking ios-stub redirect removed (native perfect, JS never arrives)"

# M3 — REQUEST HEADERS DROPPED. The request still connects and the server still
# answers 200, so status, body and the error path all stay green. Only the POST
# echo assertion can see it. This is why the fixture makes the server report
# what it ACTUALLY received instead of trusting the response code.
mutate "$NET" \
  "      req << k << \": \" << v << \"\r\n\";" \
  "      (void)k; (void)v;  // MUTANT: custom request headers dropped"
expect_red "M3 custom request headers silently dropped (server still answers 200)"

# M4 — RESPONSE HEADERS DROPPED. The body arrives perfectly, so a body-only
# assertion cannot see this at all — and header loss breaks content-type
# negotiation, auth flows and pagination in an app.
mutate "$NET" \
  "      res.headers[trim(line.substr(0, colon))] = trim(line.substr(colon + 1));" \
  "      continue;  // MUTANT: response headers discarded"
expect_red "M4 response headers discarded (body still arrives intact)"

# M5 — THE STATUS CODE HARDCODED TO 200. Every request "succeeds". A fixture
# asserting only that a request completed would pass; this is why the server
# answers 418 on /status and the fixture demands that exact number.
mutate "$NET" \
  "    stream >> httpVersion >> res.status;" \
  "    stream >> httpVersion >> res.status; res.status = 200;  // MUTANT"
expect_red "M5 status code hardcoded to 200 (every request looks successful)"

# M6 — RESPONSETYPE IGNORED (a defect this phase actually shipped). Raw text is
# returned where base64 was requested. --test-http stays fully green because it
# never goes through XMLHttpRequest; the app dies inside base64-js with
# "Invalid string. Length must be a multiple of 4" — an error naming neither
# networking nor this module.
mutate "$NET" \
  "      if (responseType == \"base64\" || responseType == \"blob\") {" \
  "      if (false) {  // MUTANT: responseType ignored"
expect_red "M6 responseType ignored — base64 requested, raw text returned"

# M7 — CHUNKED DECODING REMOVED (a defect this phase actually shipped). The
# server picks the framing, not us: Node sends Transfer-Encoding: chunked by
# DEFAULT whenever a response has no explicit Content-Length. Without decoding,
# JS receives the chunk-SIZE LINE as the body. The engine's own --test-http
# cannot catch this, because that server sets Content-Length.
mutate "$NET" \
  "      if (toLower(k) == \"transfer-encoding\" &&" \
  "      if (false && toLower(k) == \"transfer-encoding\" &&  // MUTANT: no de-chunking"
expect_red "M7 chunked responses not decoded (chunk-size line leaks in as the body)"

# M8 — THE NETWORK SETTLE REMOVED (a defect this phase actually shipped). An
# idle JS thread does not mean the network finished: a request in flight has no
# pending JS task, so the headless capture screenshots before any response has
# landed. The transport is completely healthy and every request swatch is red —
# a working stack presenting exactly like a dead one.
mutate "$MAIN" \
  "      while (net->inFlight.load() > 0 &&" \
  "      while (false && net->inFlight.load() > 0 &&  // MUTANT: no network settle"
expect_red "M8 network settle removed (frame captured before any response lands)"

echo
echo "=== restoring and re-verifying the baseline ==="
restore_files_only
bash tools/ci-p10.sh > "$BACKUP/final.log" 2>&1 \
  || { echo "TREE DID NOT RESTORE — the gate is red after cleanup:"; tail -20 "$BACKUP/final.log"; exit 1; }
echo "    ✅ baseline green again"

echo
echo "mutants caught: $PASSED   UNCAUGHT: $FAILED"
[ "$FAILED" -eq 0 ] || { echo "P10_MUTATION_FAIL: the gate does not detect $FAILED mutant(s)"; exit 1; }
echo "P10_MUTATION_PASS ($PASSED/8 mutants caught)"
