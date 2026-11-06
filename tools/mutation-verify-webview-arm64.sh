#!/usr/bin/env bash
# Prove tools/ci-webview-arm64.sh can FAIL: one mutant per arm. Each breaks one
# behaviour, rebuilds what it touched (arm64 engine or arm64 helper), runs only
# the arm that must catch it, and must be killed BY THAT ARM'S RULE. Sources
# are restored with cp + touch (never cp -p: an old mtime keeps the mutant
# linked in), and the full gate runs once more at the end to prove the restore.
#   MUTANTS="P T" bash tools/mutation-verify-webview-arm64.sh   (default: P T N F S D R)
#
#   P  pixels    helper skips the BGRA->RGBA swizzle: page colours come out R/B
#                swapped in the engine readback (the RN bar, drawn by the engine,
#                does not change, so only the page points can catch it)
#   T  touch     WebViewInput forgets the view's origin in y: a tap at window
#                100,145 lands at page 100,145 (the 40 px RN bar not subtracted)
#   N  nohelper  a dead helper no longer emits onError to the view
#   F  eme       (linux matrix M6, network) the helper stops forwarding web view frames
#                after the 10th: the decrypted video never reaches the ENGINE texture
#   S  eme       the engine's --screenshot-series no longer waits for the gate
#                (the when-file is not removed): 8 captures in a burst, so the
#                motion/clock rule sees no playback even though the video plays
#   D  helper-exit  the double free at view destroy is back: the helper aborts in
#                its teardown (no qemu core: the gate reads the engine's
#                webview_helper_exit line, not a core file)
#   R  helper-exit  the engine no longer quits + reaps its helper at exit
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="$HOME/.local/bin:$PATH"
LOGDIR="${TMPDIR:-/tmp}/mutation-webview-arm64"
mkdir -p "$LOGDIR"
SAVE="$(mktemp -d)"
killed=0 survived=0

rebuild() {
  case "$1" in
    engine) bash tools/engine-build-linux-arm64.sh > "$LOGDIR/build.log" 2>&1 ;;
    helper) bash tools/webhelper-build.sh --arch arm64 > "$LOGDIR/build.log" 2>&1 ;;
  esac || { echo "MUTANT build failed ($1), see $LOGDIR/build.log"; return 1; }
}

# mutant <id> <file> <old> <new> <rebuild> <arms> <expected-ERE>
mutant() {
  local id="$1" file="$2" old="$3" new="$4" kind="$5" arms="$6" expect="$7"
  case " ${MUTANTS:-P T N F S D R} " in *" $id "*) ;; *) return 0 ;; esac
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
    ARMS="$arms" bash tools/ci-webview-arm64.sh > "$LOGDIR/$id.log" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
      echo "MUTANT $id SURVIVED ($arms)"; survived=$((survived + 1))
    elif grep -Eq "$expect" "$LOGDIR/$id.log"; then
      echo "MUTANT $id killed: $(grep -m1 -E 'WEBVIEW(_ARM64)?_FAIL' "$LOGDIR/$id.log" | cut -c1-200)"; killed=$((killed + 1))
    else
      echo "MUTANT $id killed, but NOT by the expected rule /$expect/: $(grep -m1 -E 'WEBVIEW(_ARM64)?_FAIL' "$LOGDIR/$id.log" | cut -c1-200)"
      survived=$((survived + 1))
    fi
  else
    survived=$((survived + 1))
  fi
  cp "$SAVE/$id.orig" "$file" && touch "$file"
  rebuild "$kind" || exit 1
}

E=engine/webview H=engine/webview/helper
mutant P $H/frames.cpp '      d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = s[3];' \
  '      d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3];' helper pixels \
  'pixels: page-header at 300,70 is \(229, 136, 30\)'
mutant T $E/WebViewInput.cpp '  *ly = y - hit.y;' '  *ly = y;' engine touch \
  'touch: (touchstart|click) landed at page 100,145'
mutant N $E/WebViewHostLinux.cpp '      Emit(id, "error", j);
' '' engine nohelper 'nohelper: a missing helper did not reach onError'
mutant F $H/frames.cpp '  if (w > 0 && h > 0) Write(v, bytes, w, h, stride);' \
  '  if (w > 0 && h > 0 && v->frames.seq < 10) Write(v, bytes, w, h, stride);' helper eme \
  'eme: verdict NOT_PLAYING, wanted PLAYING'
mutant S engine/host/main.cpp '        std::remove(gScreenshotWhenFile.c_str());  // the gate asks for the next one
' '' engine eme 'eme: verdict NOT_PLAYING, wanted PLAYING'
mutant D $H/view.cpp '         (unsigned long long)v->frames.seq, (unsigned long long)v->frames.dropped);
}' '         (unsigned long long)v->frames.seq, (unsigned long long)v->frames.dropped);
  delete v;
}' helper pixels 'helper-exit\(page\): (abort in the run|the web helper did not exit cleanly)'
mutant R $E/WebViewHostLinux.cpp '    if (link) link->Stop(ms && *ms ? atoi(ms) : 3000);' '    (void)link; (void)ms;' \
  engine pixels 'helper-exit\(page\): 0 webview_helper_exit lines'

rm -rf "$SAVE"
echo "post-restore gate:"
RARMS="pixels touch nohelper"
case " ${MUTANTS:-P T N F S D R} " in *" F "*|*" S "*) RARMS="$RARMS eme eme-nocdm eme-skipdecrypt eme-g3112" ;; esac
if ARMS="$RARMS" bash tools/ci-webview-arm64.sh > "$LOGDIR/restore.log" 2>&1; then echo "  $(tail -1 "$LOGDIR/restore.log")"; else echo "  RESTORE GATE FAILED: $(grep -m1 -E 'WEBVIEW(_ARM64)?_FAIL' "$LOGDIR/restore.log")"; survived=$((survived + 1)); fi
echo "MUTATION_WEBVIEW_ARM64 killed=$killed survived=$survived"
[ $survived -eq 0 ]
