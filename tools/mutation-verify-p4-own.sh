#!/usr/bin/env bash
# MUTATION TEST for ci-p4.sh's OWN_SPEC_FOR branch (LAYER2, ENG-04 AppStorage).
#
# WHY THIS EXISTS
# ---------------
# The new branch checks an engine-vended module against THIS PACKAGE's shipped
# JS by CALL SITE (`.readFile(`), not by declaration. That is a different anchor
# from the react-native branch beside it, and an anchor that matches nothing
# fails loudly while an anchor that matches everything is silent forever. A
# guard nobody has watched go red is not a guard.
#
# Two mutants, both applied to the PACKAGE SOURCE that gets packed and
# installed, because that is what the gate actually reads:
#
#   M1  delete the readFile CALL from src/storage/index.js
#       -> the engine still vends AppStorage.readFile, nothing calls it.
#          Expect: LAYER2 names readFile as having no caller.
#
#   M2  drop src/storage from the tarball allowlist (package.json `files`)
#       -> the JS half never ships. Expect LAYER1 to name the missing file.
#          This is the failure LAYER1 was extended for, and it is separate
#          from M1: a present-but-wrong file and an absent file are different
#          defects and must produce different messages.
#
# Both mutants are reverted on exit, including on failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STORAGE="package/src/storage/index.js"
PKGJSON="package/package.json"
BACKUP="$(mktemp -d)"
cp "$STORAGE" "$BACKUP/index.js"
cp "$PKGJSON" "$BACKUP/package.json"

restore() {
  cp "$BACKUP/index.js" "$STORAGE"
  cp "$BACKUP/package.json" "$PKGJSON"
  rm -rf "$BACKUP"
}
trap restore EXIT

# A mutant must actually CHANGE the file and must still PARSE. A syntax error
# would fail the gate for the wrong reason and score as "the guard fired".
assert_mutated() {
  cmp -s "$1" "$2" && { echo "MUTATE_FAIL: mutant did not change $1" >&2; exit 1; }
  node --check "$1" 2>/dev/null || node -e "JSON.parse(require('fs').readFileSync('$1','utf8'))" \
    || { echo "MUTATE_FAIL: mutant broke the syntax of $1 — a parse error is not a guard firing" >&2; exit 1; }
}

run_gate() { bash tools/ci-p4.sh > "$1" 2>&1; }

echo "== BASELINE: the gate must be GREEN before any mutation means anything =="
if ! run_gate "$BACKUP/base.log"; then
  tail -20 "$BACKUP/base.log" >&2
  echo "MUTATE_FAIL: ci-p4.sh is already red — a mutation test on a red gate proves nothing" >&2
  exit 1
fi
grep -q 'P4_MODULES_PASS' "$BACKUP/base.log" || {
  echo "MUTATE_FAIL: baseline did not print P4_MODULES_PASS" >&2; exit 1; }
echo "   baseline green: $(grep -o 'LAYER2 ok.*' "$BACKUP/base.log")"

echo
echo "== M1: remove the readFile CALL from the shipped storage JS =="
node -e '
const fs = require("fs");
const p = "package/src/storage/index.js";
let s = fs.readFileSync(p, "utf8");
// getItem is the only readFile call site. Replace the call with a literal so
// the file still parses and still exports the same API surface.
s = s.replace("return mod().readFile(encodeKey(key));", "return null; // MUTANT M1");
fs.writeFileSync(p, s);
'
assert_mutated "$STORAGE" "$BACKUP/index.js"
if run_gate "$BACKUP/m1.log"; then
  echo "MUTATE_FAIL: M1 SURVIVED — readFile has no caller and the gate stayed green." >&2
  echo "             The OWN_SPEC_FOR branch is blind; it is not checking anything." >&2
  exit 1
fi
if ! grep -q 'AppStorage.readFile() has no caller' "$BACKUP/m1.log"; then
  echo "MUTATE_FAIL: M1 killed the gate, but NOT for the right reason. Message was:" >&2
  grep -A5 'P4_MODULES_FAIL' "$BACKUP/m1.log" >&2 || tail -10 "$BACKUP/m1.log" >&2
  exit 1
fi
echo "   M1 killed, correctly: $(grep -o 'LAYER2: native method AppStorage.readFile.*' "$BACKUP/m1.log" | head -1)"
cp "$BACKUP/index.js" "$STORAGE"

echo
echo "== M2: drop src/storage from the tarball allowlist =="
node -e '
const fs = require("fs");
const p = "package/package.json";
const j = JSON.parse(fs.readFileSync(p, "utf8"));
// `files: ["src", ...]` ships the whole tree, so the only honest way to make
// storage/ absent is an explicit negation, which npm honours.
j.files = j.files.concat(["!src/storage"]);
fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
'
assert_mutated "$PKGJSON" "$BACKUP/package.json"
if run_gate "$BACKUP/m2.log"; then
  echo "MUTATE_FAIL: M2 SURVIVED — the storage JS was excluded from the tarball" >&2
  echo "             and LAYER1 did not notice. The allowlist check is blind." >&2
  exit 1
fi
if ! grep -qE 'LAYER1: tarball is missing src/storage/index.js|the JS half of .AppStorage. did not ship' "$BACKUP/m2.log"; then
  echo "MUTATE_FAIL: M2 killed the gate, but NOT for the right reason. Message was:" >&2
  grep -A5 'P4_MODULES_FAIL' "$BACKUP/m2.log" >&2 || tail -10 "$BACKUP/m2.log" >&2
  exit 1
fi
echo "   M2 killed, correctly: $(grep -oE '(LAYER1: tarball is missing src/storage.*|LAYER2: .*did not ship)' "$BACKUP/m2.log" | head -1)"

echo
echo "MUTATE_P4_OWN_OK — 2 mutants, 2 killed, each with its own message"
