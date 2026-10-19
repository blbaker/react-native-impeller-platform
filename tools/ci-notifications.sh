#!/usr/bin/env bash
# Notifications gate (Linux): show() makes a real org.freedesktop.Notifications
# Notify call on a session bus, and a click on it reaches JS as one press.
#
# Everything runs against a PRIVATE dbus-daemon in a temp dir, never the
# desktop's session bus, so the gate shows nothing on screen and cannot be
# confused by a real notification server.
#
#   A  vended    --list-modules shows Notifications with both methods
#   B  present   tools/notify_bus_mock.py owns the server name: the Notify
#                call carries the title/body/actions JS passed (read by the
#                mock AND by dbus-monitor, two independent decoders), the
#                click arrives as exactly ONE press with the data JS attached
#                (a spoofed click and another app's click must not count),
#                and showing the same id again sends replaces_id
#   C  no server the bus is up but nobody owns the name: "unavailable"
#   D  no bus    DBUS_SESSION_BUS_ADDRESS points at nothing: "unavailable"
#
# Every JS-side value is read from an Alert title the fixture produced, so a
# perfect native call that JS never hears about fails here.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "NOTIFY_GATE_FAIL: $*" >&2; exit 1; }

command -v dbus-daemon >/dev/null \
  || fail "dbus-daemon is not installed (Debian/Ubuntu: apt-get install dbus-daemon)"
command -v dbus-monitor >/dev/null || fail "dbus-monitor is not installed"
[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
SIDE_PIDS=""
cleanup() {
  for p in $SIDE_PIDS; do kill "$p" 2>/dev/null || true; done
  for p in $SIDE_PIDS; do wait "$p" 2>/dev/null || true; done
  rni_kill_own
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/NotifyApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="notifyapp"; fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="NotifyFixture"; a.displayName="NotifyFixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"
SHIPPED="$APP/node_modules/react-native-impeller-platform/src/notifications"
[ -f "$SHIPPED/index.js" ] && [ -f "$SHIPPED/index.d.ts" ] \
  || fail "src/notifications (index.js + index.d.ts) is NOT in the packed tarball"

echo "== 2. fixture + bundle =="
cp "$ROOT/fixtures/notifications/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/react-native-impeller-platform/src/bin/engine-path.js)" \
  || fail "engine resolver failed"
BUNDLE="$WORK/notify.bundle"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output "$BUNDLE" >/dev/null 2>&1 \
  || fail "bundle failed"
[ -s "$BUNDLE" ] || fail "no bundle produced"

echo "== 3. a private session bus =="
cat > "$WORK/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$WORK/bus.sock</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
dbus-daemon --config-file="$WORK/bus.conf" --nofork --nopidfile >"$WORK/bus.log" 2>&1 &
SIDE_PIDS="$SIDE_PIDS $!"
ADDR="unix:path=$WORK/bus.sock"
for _ in $(seq 50); do [ -S "$WORK/bus.sock" ] && break; sleep 0.1; done
[ -S "$WORK/bus.sock" ] || fail "private dbus-daemon did not start: $(tail -2 "$WORK/bus.log")"

run_fixture() {  # mode bus-address log
  DBUS_SESSION_BUS_ADDRESS="$2" RNI_APP_NAME="Notify Fixture" timeout 90 \
    "$ENGINE" --bundle "$BUNDLE" --app-name NotifyFixture --headless \
      --probe-banner off --width 400 --height 300 \
      --initial-url "rninotify://$1" > "$3" 2>&1 \
    || { tail -20 "$3" >&2; fail "the $1 run exited non-zero"; }
  grep -q "scene_nodes=[1-9]" "$3" || fail "the $1 run mounted nothing (wrong --app-name?)"
}
alert() { grep -o "alert=notif $1.*" "$2" | head -1 || true; }
want() {  # label pattern log
  local got
  got="$(alert "$1" "$3")"
  [ -n "$got" ] || { grep -o 'alert=notif.*' "$3" >&2 || true; fail "no '$1' alert from JS"; }
  echo "$got" | grep -qE "$2" || fail "unexpected JS result: $got (wanted /$2/)"
  echo "   OK JS: ${got#alert=}"
}

echo "== 4. arm A: the module is vended =="
"$ENGINE" --list-modules > "$WORK/mods.log" 2>&1 || true
grep -qE "module=Notifications methods=.*requestPermission" "$WORK/mods.log" \
  && grep -qE "module=Notifications methods=.*show" "$WORK/mods.log" \
  || fail "Notifications is not vended with requestPermission + show (see --list-modules)"
echo "   OK: $(grep -o 'module=Notifications methods=[a-zA-Z,]*' "$WORK/mods.log")"

echo "== 5. arm B: a notification server is on the bus =="
dbus-monitor --address "$ADDR" \
  "type='method_call',interface='org.freedesktop.Notifications'" > "$WORK/monitor.log" 2>&1 &
SIDE_PIDS="$SIDE_PIDS $!"
python3 "$ROOT/tools/notify_bus_mock.py" --address "$ADDR" --log "$WORK/calls.jsonl" \
  --ready "$WORK/mock.ready" > "$WORK/mock.log" 2>&1 &
MOCK_PID=$!
SIDE_PIDS="$SIDE_PIDS $MOCK_PID"
for _ in $(seq 50); do [ -s "$WORK/mock.ready" ] && break; sleep 0.1; done
[ -s "$WORK/mock.ready" ] || fail "bus mock did not start: $(tail -3 "$WORK/mock.log")"
run_fixture press "$ADDR" "$WORK/press.log"
# The wire first: this is the arm that fails when show() never reaches D-Bus.
python3 "$ROOT/tools/notify_gate_check.py" "$WORK/calls.jsonl" "$WORK/monitor.log" \
  || fail "the D-Bus traffic does not match what JS asked for (see above)"
want "perm=" "^alert=notif perm=granted bad=rejected$" "$WORK/press.log"
want "show=" "^alert=notif show=shown id=edition-42$" "$WORK/press.log"
want "press " '^alert=notif press n=1 id=edition-42 action=default data=\{"edition":42,"kind":"edition"\}$' "$WORK/press.log"
want "replace=" "^alert=notif replace=shown id=edition-42$" "$WORK/press.log"
want "done" "^alert=notif done$" "$WORK/press.log"

echo "== 6. arm C: bus up, no notification server =="
kill "$MOCK_PID" 2>/dev/null || true
wait "$MOCK_PID" 2>/dev/null || true
run_fixture absent "$ADDR" "$WORK/absent.log"
want "perm=" "^alert=notif perm=unavailable bad=rejected reason=no notification server" "$WORK/absent.log"
want "show=" "^alert=notif show=unavailable id=edition-42 reason=no notification server" "$WORK/absent.log"
want "done" "^alert=notif done$" "$WORK/absent.log"

echo "== 7. arm D: no session bus at all =="
run_fixture absent "unix:path=$WORK/no-such-bus" "$WORK/nobus.log"
want "perm=" "^alert=notif perm=unavailable bad=rejected reason=no D-Bus session bus" "$WORK/nobus.log"
want "show=" "^alert=notif show=unavailable id=edition-42 reason=no D-Bus session bus" "$WORK/nobus.log"
want "done" "^alert=notif done$" "$WORK/nobus.log"

echo "NOTIFY_GATE_PASS (vended + Notify on the wire + one press with data + replace + unavailable without a server or a bus)"
