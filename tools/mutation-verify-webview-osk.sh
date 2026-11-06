#!/usr/bin/env bash
# Prove tools/ci-webview-osk.sh can FAIL: each mutant breaks one piece of the app
# keyboard path, rebuilds what it touched (engine / helper / bundle), runs the gate
# and must be killed BY THE EXPECTED RULE. Sources are restored with cp + touch
# (never cp -p: an old mtime makes ninja keep the mutant linked in), and both gates
# run once more at the end to prove the restore.
#   MUTANTS="O1 O3" bash tools/mutation-verify-webview-osk.sh   (default: all)
#   O1 the helper drops the editableFocus event
#   O2 the helper drops the commit (sendText reaches the helper, nothing is inserted)
#   O3 sendKey maps every key to nothing (no key reaches the helper)
#   O4 isPassword is never true
#   O5 a purpose change while focused (text field -> password field) is not reported
#   O6 notify_focus_out is not handled (a blur is never reported)
#   O7 the JS shim never calls the onEditableFocus prop (raw event only)
#   O8 sendText is not registered on the TurboModule (the JS guard must throw)
#   O9 the IM context swallows every key: ci-webview.sh's PHYSICAL typing arm must catch it
#   O10 the router ignores setKeepFocus (a press outside always blurs, today's bug)
#   O11 keep-focus never clears (any focused view is kept: the negative control must catch it)
#   O12 the JS shim's setKeepFocus never reaches the engine
#   O13 setKeepFocus(false) does not blur (a tap on the still-focused field reports nothing)
#   O14 it blurs the page but the engine keeps the view focused (keys still go to it)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="$HOME/.local/bin:$PATH"
eval "$(bash tools/webhelper-debian-x64.sh env)"
LOGDIR="${TMPDIR:-/tmp}/mutation-webview-osk"
mkdir -p "$LOGDIR"
SAVE="$(mktemp -d)"
ALL="O1 O2 O3 O4 O5 O6 O7 O8 O9 O10 O11 O12 O13 O14"
killed=0 survived=0

rebuild() {
  case "$1" in
    engine) bash tools/engine-build.sh linux x64 > "$LOGDIR/build.log" 2>&1 ;;
    helper) bash tools/webhelper-debian-x64.sh build > "$LOGDIR/build.log" 2>&1 ;;
    bundle) bash tools/build-fixture-bundle.sh webview-osk WebViewOskGate > "$LOGDIR/build.log" 2>&1 ;;
  esac || { echo "MUTANT build failed ($1), see $LOGDIR/build.log"; return 1; }
}

gate() {
  case "$1" in
    osk) bash tools/ci-webview-osk.sh ;;
    physical) ARMS=main bash tools/ci-webview.sh ;;
  esac
}

# mutant <id> <file> <old> <new> <rebuild> <gate> <expected-ERE>
mutant() {
  local id="$1" file="$2" old="$3" new="$4" kind="$5" which="$6" expect="$7"
  case " ${MUTANTS:-$ALL} " in *" $id "*) ;; *) return 0 ;; esac
  cp "$file" "$SAVE/$id.orig"
  python3 - "$file" "$old" "$new" <<'PY' || { echo "MUTANT $id: anchor not found exactly once in $2"; exit 1; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  if rebuild "$kind"; then
    gate "$which" > "$LOGDIR/$id.log" 2>&1
    local rc=$?
    local why
    why="$(grep -m1 -E 'WEBVIEW_OSK_FAIL|WEBVIEW_FAIL|DRIVE_FAIL' "$LOGDIR/$id.log" | cut -c1-200)"
    if [ $rc -eq 0 ]; then
      echo "MUTANT $id SURVIVED ($which)"; survived=$((survived + 1))
    elif grep -Eq "$expect" "$LOGDIR/$id.log"; then
      echo "MUTANT $id killed: $why"; killed=$((killed + 1))
    else
      echo "MUTANT $id killed, but NOT by the expected rule /$expect/: $why"; survived=$((survived + 1))
    fi
  else
    survived=$((survived + 1))
  fi
  cp "$SAVE/$id.orig" "$file" && touch "$file"
  rebuild "$kind" || exit 1
}

H=engine/webview/helper/input.cpp M=engine/modules/WebViewModule.h
mutant O1 $H '  SendEvent(c->view->id, "editableFocus",' '  if (false) SendEvent(c->view->id, "editableFocus",' \
  helper osk "focus-text: no editableFocus after the 'text' tap"
mutant O2 $H '  g_signal_emit_by_name(v->im, "committed", text.c_str());' '  (void)text;' \
  helper osk 'commit: no single beforeinput carrying "abc"'
mutant O3 $M '    host().Key(v, true, sym, 0, 0);
    host().Key(v, false, sym, 0, 0);' '    (void)v;' engine osk 'backspace: no keydown Backspace'
mutant O4 $H '  const bool password = focused && p == WEBKIT_INPUT_PURPOSE_PASSWORD;' '  const bool password = false;' \
  helper osk "focus-password: the 'password' tap gave"
mutant O5 $H '  if (Im(o)->focused) ReportFocus(Im(o), true);' '  (void)o;' \
  helper osk "focus-password: no editableFocus after the 'password' tap"
mutant O6 $H '  klass->parent.notify_focus_out = [](WebKitInputMethodContext* c) { ReportFocus(Im(c), false); };' '' \
  helper osk "focus-blank: no editableFocus after the 'blank' tap"
mutant O7 package/src/webview/index.js "      case 'editableFocus': if (p.onEditableFocus) p.onEditableFocus({nativeEvent}); break;" '' \
  bundle osk "focus-text: no editableFocus after the 'text' tap"
mutant O8 $M '    methodMap_["sendText"] = MethodMetadata{2, sendTextHost};' '' \
  engine osk 'commit: no single beforeinput carrying "abc"'
mutant O9 $H '  klass->parent.notify_focus_out = [](WebKitInputMethodContext* c) { ReportFocus(Im(c), false); };' \
  '  klass->parent.notify_focus_out = [](WebKitInputMethodContext* c) { ReportFocus(Im(c), false); };
  klass->parent.filter_key_event = [](WebKitInputMethodContext*, gpointer) -> gboolean { return TRUE; };' \
  helper physical 'DRIVE_FAIL timeout waiting for /WVPAGE value "ab"'
mutant O10 engine/webview/WebViewInput.cpp '      if (const int64_t kept = H().PressOutside()) Log("keep_focus", kept, x, y);' \
  '      H().SetFocused(0);' \
  engine osk 'keep-key-t: no kept focus on the press outside the web view'
mutant O11 engine/webview/WebViewHost.h '    if (focused_ && keep_.count(focused_)) return focused_;' '    if (focused_) return focused_;' \
  engine osk "keep-off: focus kept on the 'rn-chrome' press"
mutant O12 package/src/webview/index.js "return idRef.current && Native.setKeepFocus(idRef.current, !!keep);" \
  'return keep && false;' bundle osk 'keep-set: no setKeepFocus\(true\) reaching the engine'
mutant O13 engine/webview/WebViewHost.h '    if (blur) MoveFocusLocked(0);' '    (void)0;' \
  engine osk "refocus-1: no editableFocus \(the same field tapped after Done\)"
mutant O14 engine/webview/WebViewHost.h '    if (blur) MoveFocusLocked(0);' '    if (blur) Focus(id, false);' \
  engine osk 'phys-key: a physical key after Done still went to the page'

rm -rf "$SAVE"
echo "post-restore gates:"
for which in osk physical; do
  if gate "$which" > "$LOGDIR/restore-$which.log" 2>&1; then echo "  $which: $(tail -1 "$LOGDIR/restore-$which.log")"
  else echo "  $which RESTORE GATE FAILED: $(grep -m1 -E 'WEBVIEW_OSK_FAIL|WEBVIEW_FAIL' "$LOGDIR/restore-$which.log")"; survived=$((survived + 1)); fi
done
echo "MUTATION_WEBVIEW_OSK killed=$killed survived=$survived"
[ $survived -eq 0 ]
