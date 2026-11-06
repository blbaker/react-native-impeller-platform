#!/usr/bin/env bash
# Proves tools/ci-webview-release.sh can FAIL: each mutant breaks the helper's
# web-process release, the helper is rebuilt, and the gate must reject it.
#   W1  no cache model call at all (WebKit default WEB_BROWSER)
#   W2  the call sets WEB_BROWSER explicitly
#   W3  the model is set only AFTER the first view built the process pool
#       (capacity is fixed at pool construction: the order matters)
# Restores with cp + touch (never cp -p: an old mtime lets ninja/g++ skip the
# rebuild), then reruns the gate on the restored source, which must PASS.
set -euo pipefail
cd "$(dirname "$0")/.."
export TMPDIR="${TMPDIR:-/tmp}"
eval "$(bash tools/webhelper-debian-x64.sh env)"
MAIN=engine/webview/helper/main.cpp VIEW=engine/webview/helper/view.cpp
BK="$(mktemp -d "$TMPDIR/mut-webview-release.XXXXXX")"
cp "$MAIN" "$BK/main.cpp"; cp "$VIEW" "$BK/view.cpp"
restore() { cp "$BK/main.cpp" "$MAIN"; cp "$BK/view.cpp" "$VIEW"; touch "$MAIN" "$VIEW"; }
trap restore EXIT
CALL='webkit_web_context_set_cache_model(nullptr, WEBKIT_CACHE_MODEL_DOCUMENT_BROWSER);'
grep -qF "$CALL" "$MAIN" || { echo "MUTATION_FAIL: anchor not found in $MAIN"; exit 1; }
killed=0 total=0
mutant() {
  local id="$1"; total=$((total + 1))
  bash tools/webhelper-debian-x64.sh build >/dev/null 2>&1 || { echo "MUTANT $id: build failed (not a kill)"; exit 1; }
  if bash tools/ci-webview-release.sh > "$BK/$id.log" 2>&1; then
    echo "MUTANT $id SURVIVED"; tail -5 "$BK/$id.log"
  else
    killed=$((killed + 1)); echo "MUTANT $id killed: $(grep -o 'WEBVIEW_RELEASE_FAIL.*' "$BK/$id.log" | head -1)"
  fi
  restore
}
python3 - "$MAIN" "$CALL" <<'EOF'
import sys; p, c = sys.argv[1:]; s = open(p).read(); open(p, "w").write(s.replace(c, "/* W1 */"))
EOF
mutant W1
python3 - "$MAIN" "$CALL" <<'EOF'
import sys; p, c = sys.argv[1:]; s = open(p).read()
open(p, "w").write(s.replace(c, c.replace("DOCUMENT_BROWSER", "WEB_BROWSER")))
EOF
mutant W2
python3 - "$MAIN" "$VIEW" "$CALL" <<'EOF'
import sys; m, v, c = sys.argv[1:]
s = open(m).read(); open(m, "w").write(s.replace(c, "/* W3: moved */"))
anchor = "  g_object_unref(s);\n"
t = open(v).read(); assert anchor in t; open(v, "w").write(t.replace(anchor, anchor + "  " + c + "\n", 1))
EOF
mutant W3
bash tools/webhelper-debian-x64.sh build >/dev/null 2>&1
bash tools/ci-webview-release.sh > "$BK/restored.log" 2>&1 || { echo "MUTATION_FAIL: restored source fails the gate"; tail -5 "$BK/restored.log"; exit 1; }
grep -n -E '/\* W[0-9]' "$MAIN" "$VIEW" && { echo "MUTATION_FAIL: mutant residue"; exit 1; }
echo "restored source: WEBVIEW_RELEASE_GATE_PASS"
[ "$killed" = "$total" ] || { echo "MUTATION_FAIL killed=$killed/$total"; exit 1; }
echo "MUTATION_VERIFY_WEBVIEW_RELEASE_PASS killed=$killed/$total"
trap - EXIT
rm -rf "$BK"
