#!/usr/bin/env bash
# MUTATION TEST for tools/ci-notifications.sh: every mutant below breaks one
# thing the gate claims to prove, and the gate must fail on THAT claim's own
# assertion, then pass again once the source is restored.
#
#   M1  Linux backend stubbed out (the Null backend is linked instead)
#   M2  show() reports "shown" without sending Notify
#   M3  the signal match accepts any sender (a spoofed click counts)
#   M4  a click on another app's notification is forwarded
#   M5  the press loses the data JS attached
#   M6  showing the same id again does not send replaces_id
#   M7  title and body swapped on the wire
#   M8  the module is not registered
#   M9  "no server" reported as an error instead of "unavailable"
#   M10 the JS half hands the raw JSON string to the listener (no rebuild)
#
# Sources are restored with cp + touch, never cp -p: a restored file with its
# old mtime is older than the mutant's object file, ninja skips the rebuild,
# and every later run tests the mutant.
set -euo pipefail
cd "$(dirname "$0")/.."

LNX=engine/modules/NotificationsLinux.cpp
RH=engine/runtime/ReactHost.cpp
CM=engine/CMakeLists.txt
JS=package/src/notifications/index.js
FILES=("$LNX" "$RH" "$CM" "$JS")
BAK="$(mktemp -d)"
for f in "${FILES[@]}"; do cp "$f" "$BAK/$(basename "$f")"; done

put_back() {
  for f in "${FILES[@]}"; do
    cmp -s "$BAK/$(basename "$f")" "$f" || { cp "$BAK/$(basename "$f")" "$f"; touch "$f"; }
  done
}
build() { bash tools/engine-build.sh linux x64 > "$BAK/build.log" 2>&1; }
restore() {
  put_back
  build || echo "WARN: rebuild of the restored tree failed" >&2
  trap - EXIT
  rm -rf "$BAK"
}
trap restore EXIT
fail() { echo "NOTIFY_MUTATION_FAIL: $*" >&2; exit 1; }
run_gate() { set +e; bash tools/ci-notifications.sh > "$1" 2>&1; local rc=$?; set -e; return $rc; }

cat > "$BAK/mut.py" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
n = s.count(old)
assert n == 1, f"mutation anchor found {n}x in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY
mutate() { python3 "$BAK/mut.py" "$1" "$2" "$3"; }

check() {  # name, expected-failure-substring, [nobuild]
  if [ "${3:-}" != "nobuild" ]; then
    build || { tail -15 "$BAK/build.log" >&2; fail "$1 tree did not build"; }
  fi
  if run_gate "$BAK/$1.log"; then fail "$1 SURVIVED: the gate passed with the mutant in"; fi
  grep -qF -- "$2" "$BAK/$1.log" || {
    grep -E "NOTIFY_GATE_FAIL|BUS:" "$BAK/$1.log" >&2 || true
    fail "$1 was killed by the WRONG assertion (wanted: $2)"
  }
  echo "   OK: $1 killed ($(grep -oE '^   BUS: .*|NOTIFY_GATE_FAIL: .*' "$BAK/$1.log" | head -1 | sed 's/^ *//' | cut -c1-110))"
  put_back
}

echo "== control: the unmutated tree must PASS =="
build || fail "control tree did not build"
run_gate "$BAK/control.log" || { tail -8 "$BAK/control.log" >&2; fail "control FAILED: nothing below means anything"; }
echo "   OK: control passes"

echo "== M1: Linux backend stubbed out =="
mutate "$CM" "set(RNI_NOTIFICATIONS_BACKEND modules/NotificationsLinux.cpp)" \
  "set(RNI_NOTIFICATIONS_BACKEND modules/NotificationsNull.cpp)"
check M1 "expected 1 GetCapabilities (requestPermission), got 0"

echo "== M2: shown without a Notify call =="
mutate "$LNX" '    uint32_t replaces = 0;' '    if (!q.id.empty()) return {"shown", ""};
    uint32_t replaces = 0;'
check M2 "expected 2 Notify calls (show + replace), got 0"

echo "== M3: signals accepted from any sender =="
mutate "$LNX" 'r = a.match_signal(bus, nullptr, kName, kPath, kIface, "ActionInvoked",' \
  'r = a.match_signal(bus, nullptr, nullptr, kPath, kIface, "ActionInvoked",'
check M3 "unexpected JS result: alert=notif press n=2 id=edition-42"

echo "== M4: another app's click forwarded =="
mutate "$LNX" 'if (!ours || std::strcmp(action, "default") != 0) return 0;' \
  'if (std::strcmp(action, "default") != 0) return 0;'
mutate "$LNX" 'self->onPress_(Press{it->second.id, it->second.data, "default"});' \
  'self->onPress_(ours ? Press{it->second.id, it->second.data, "default"} : Press{"", "null", "default"});'
check M4 "unexpected JS result: alert=notif press n=2 id= action"

echo "== M5: press loses the data =="
mutate "$LNX" 'self->onPress_(Press{it->second.id, it->second.data, "default"});' \
  'self->onPress_(Press{it->second.id, "null", "default"});'
check M5 "unexpected JS result: alert=notif press n=1 id=edition-42 action=default data=null"

echo "== M6: replace without replaces_id =="
mutate "$LNX" 'if (auto it = byJsId_.find(q.id); it != byJsId_.end()) replaces = it->second;' \
  '(void)byJsId_;'
check M6 "replace sent replaces_id 0, want 7001"

echo "== M7: title and body swapped =="
mutate "$LNX" 'q.title.c_str(), q.body.c_str()' 'q.body.c_str(), q.title.c_str()'
check M7 "first Notify carried 'Tuesday: 3 stories'"

echo "== M8: module not registered =="
mutate "$RH" 'modules_->add("Notifications", [n = notifications_](auto inv) {' \
  'modules_->add("NotificationsOff", [n = notifications_](auto inv) {'
check M8 "Notifications is not vended with requestPermission + show"

echo "== M9: no server reported as an error =="
mutate "$LNX" 'if (name == "org.freedesktop.DBus.Error.ServiceUnknown" ||' \
  'if (name == "org.freedesktop.DBus.Error.ServiceUnknownX" ||'
check M9 "unexpected JS result: alert=notif perm=error"

echo "== M10: JS listener gets the raw JSON string =="
# The engine binary is the restored one from M9's put_back: rebuild first so
# M10 runs against a correct engine and only the JS is wrong.
build || fail "rebuild before M10 failed"
mutate "$JS" 'data: decodeData(event.data)' 'data: event.data'
check M10 'unexpected JS result: alert=notif press n=1 id=edition-42 action=default data="' nobuild

echo "NOTIFY_MUTATION_PASS (10/10 mutants killed by their own assertion)"
