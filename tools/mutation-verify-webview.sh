#!/usr/bin/env bash
# Prove tools/ci-webview.sh can FAIL: each mutant breaks one behaviour, rebuilds
# what it touched (engine / helper / bundle), runs only the arm that should
# catch it, and must be killed BY THE EXPECTED RULE. Sources are restored with
# cp + touch (never cp -p: an old mtime makes ninja keep the mutant linked in),
# and the gate runs once more at the end to prove the restore.
#   MUTANTS="M1 M3" bash tools/mutation-verify-webview.sh   (default: all)
# M9/M10 need network + the x64 CDM, like the eme arm they target:
#   M9  the helper stops forwarding frames after the 10th (frozen engine texture)
#   M10 the engine's --screenshot-series stops waiting (8 readbacks in a burst)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="$HOME/.local/bin:$PATH"
LOGDIR="${TMPDIR:-/tmp}/mutation-webview"
mkdir -p "$LOGDIR"
SAVE="$(mktemp -d)"
killed=0 survived=0

rebuild() {
  case "$1" in
    engine) bash tools/engine-build.sh linux x64 > "$LOGDIR/build.log" 2>&1 ;;
    helper) bash tools/webhelper-build.sh > "$LOGDIR/build.log" 2>&1 ;;
    bundle) bash tools/build-fixture-bundle.sh webview WebViewGate > "$LOGDIR/build.log" 2>&1 ;;
  esac || { echo "MUTANT build failed ($1), see $LOGDIR/build.log"; return 1; }
}

# mutant <id> <file> <old> <new> <rebuild> <arms> <expected-ERE>
mutant() {
  local id="$1" file="$2" old="$3" new="$4" kind="$5" arms="$6" expect="$7"
  case " ${MUTANTS:-M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11 M12 M13} " in *" $id "*) ;; *) return 0 ;; esac
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
    ARMS="$arms" bash tools/ci-webview.sh > "$LOGDIR/$id.log" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
      echo "MUTANT $id SURVIVED ($arms)"; survived=$((survived + 1))
    elif grep -Eq "$expect" "$LOGDIR/$id.log"; then
      echo "MUTANT $id killed: $(grep -m1 -E 'WEBVIEW_FAIL' "$LOGDIR/$id.log" | cut -c1-160)"; killed=$((killed + 1))
    else
      echo "MUTANT $id killed, but NOT by the expected rule /$expect/: $(grep -m1 WEBVIEW_FAIL "$LOGDIR/$id.log" | cut -c1-160)"
      survived=$((survived + 1))
    fi
  else
    survived=$((survived + 1))
  fi
  cp "$SAVE/$id.orig" "$file" && touch "$file"
  rebuild "$kind" || exit 1
}

E=engine/webview H=engine/webview/helper
mutant M1 $E/WebViewInput.cpp '    SetFocus(id);
    capture_ = id;' '    return false;
    SetFocus(id);
    capture_ = id;' engine main 'driver did not finish: DRIVE_FAIL timeout waiting for /WVPAGE click'
mutant M2 $E/WebViewHostLinux.cpp '      tex->Publish(std::move(f));' '      (void)f;' engine main 'pixels: page-header'
mutant M3 $H/view.cpp 'if (hs) soup_message_headers_replace' 'if (false && hs) soup_message_headers_replace' helper main 'headers: first request'
mutant M4 $H/input.cpp '-dx, -dy, TRUE, FALSE, x, y)' 'dx, dy, TRUE, FALSE, x, y)' helper main 'WVPAGE scrolly'
mutant M5 $H/view.cpp '  if (g_error_matches(err, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED)) return FALSE;' '' helper main 'stopLoading reported onError'
mutant M6 $H/view.cpp '  add(v->scriptStart, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START);' '' helper main 'BeforeContentLoaded did not run'
mutant M7 $H/main.cpp '  webkit_cookie_manager_set_persistent_storage(cm, cookies.c_str(),
                                               WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);' '' helper cookies 'cookies: b.html read cookie None|read cookie .none., wanted .sess'
mutant M8 package/src/webview/index.js "      case 'loadStart': if (p.onLoadStart) p.onLoadStart({nativeEvent}); break;" '' bundle main 'no WVAPP line matching /\^ev=loadStart'
mutant M9 $H/frames.cpp '  if (w > 0 && h > 0) Write(v, bytes, w, h, stride);' \
  '  if (w > 0 && h > 0 && v->frames.seq < 10) Write(v, bytes, w, h, stride);' helper eme \
  'eme: verdict NOT_PLAYING, wanted PLAYING'
mutant M10 engine/host/main.cpp '        std::remove(gScreenshotWhenFile.c_str());  // the gate asks for the next one
' '' engine eme 'eme: verdict NOT_PLAYING, wanted PLAYING'
# Helper exit (webview_check.py helper-exit, every real-helper run):
#   M11 the double free at view destroy is back (DestroyView deletes v, the map deletes it again)
#   M12 the engine no longer quits + reaps its helper at exit (no webview_helper_exit line)
#   M13 the helper ignores kDestroy (the view is never released before the helper exits)
mutant M11 $H/view.cpp '         (unsigned long long)v->frames.seq, (unsigned long long)v->frames.dropped);
}' '         (unsigned long long)v->frames.seq, (unsigned long long)v->frames.dropped);
  delete v;
}' helper main 'helper-exit\(main\): abort in the run: .double free or corruption'
mutant M12 $E/WebViewHostLinux.cpp '    if (link) link->Stop(ms && *ms ? atoi(ms) : 3000);' '    (void)link; (void)ms;' \
  engine main 'helper-exit\(main\): 0 webview_helper_exit lines'
mutant M13 $H/main.cpp '      DestroyView(v);
      H().views.erase(m.view);' '      break;' helper main "helper-exit\\(main\\): views destroyed: engine \\['1'\\], helper \\[\\]"

rm -rf "$SAVE"
echo "post-restore gate:"
RARMS="static main"
case " ${MUTANTS:-M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11 M12 M13} " in *" M9 "*|*" M10 "*) RARMS="$RARMS eme eme-nocdm eme-skipdecrypt" ;; esac
if ARMS="$RARMS" bash tools/ci-webview.sh > "$LOGDIR/restore.log" 2>&1; then echo "  $(tail -1 "$LOGDIR/restore.log")"; else echo "  RESTORE GATE FAILED: $(grep -m1 WEBVIEW_FAIL "$LOGDIR/restore.log")"; survived=$((survived + 1)); fi
echo "MUTATION_WEBVIEW killed=$killed survived=$survived"
[ $survived -eq 0 ]
