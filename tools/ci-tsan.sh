#!/usr/bin/env bash
# FP-04: ThreadSanitizer over the cross-thread paths (JS thread, main/paint thread,
# NativeAnimated ticks, image fetch threads, teardown).
# Model: Flutter's TSan lane, engine/src/flutter/testing/sanitizer_suppressions.sh +
# tsan_suppressions.txt (third-party suppressions only), on the real binary.
#   1. builds engine/build-tsan (clang, RNI_SANITIZE=thread) and stages it
#   2. proves the binary is instrumented (__tsan_init, prints sanitizers=thread)
#   3. runs the animated / text / image / native-transform fixtures windowed (xvfb) AND
#      headless, plus the FP-04 stress fixture (text churn every 4 ms + a native-driver
#      loop), the FP-12 typography fixture, and the ci-text / ci-native-transform / ci-image-net / ci-image-io gates on the TSan binary
#   4. tools/tsan_check.py: any report outside tools/sanitize/tsan_known.txt FAILS; each
#      known entry (a race a later pass owns) must still be seen
# libimpeller.so / libhermesvm.so are prebuilt and uninstrumented: engine/base/TsanAnnotate.h
# makes our uses of single-thread Impeller objects visible at our call sites.
# Env: TSAN_RUNS="name ..." runs a subset of step 3 (the mutation script uses it).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/engine/build-tsan"
BIN="$BUILD/stage/bin/rn-impeller"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-tsan.XXXX")"
SERVER_PID="" CHURN_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; [ -n "$CHURN_PID" ] && kill "$CHURN_PID" 2>/dev/null; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "kept $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "TSAN_FAIL: $*"; exit 1; }

echo "== 1. build engine/build-tsan (RNI_SANITIZE=thread)"
cmake -S engine -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DRNI_SANITIZE=thread \
      -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_INSTALL_PREFIX="$BUILD/stage" > "$WORK/configure.log" 2>&1 \
  || { tail -20 "$WORK/configure.log"; fail "configure failed"; }
cmake --build "$BUILD" -j"$(nproc)" --target rn-impeller > "$WORK/build.log" 2>&1 \
  || { grep -m5 -A5 FAILED "$WORK/build.log"; fail "build failed"; }
rm -rf "$BUILD/stage"
cmake --install "$BUILD" --component engine > /dev/null || fail "install failed"
[ -x "$BIN" ] || fail "no staged binary at $BIN"

echo "== 2. instrumentation"
SYMS="$(nm "$BIN" 2>/dev/null)"  # whole output first: grep -q on a pipe SIGPIPEs nm under pipefail
grep -q ' __tsan_init$' <<<"$SYMS" || fail "no __tsan_init in $BIN: not TSan-instrumented"
grep -q ' __tsan_write1$' <<<"$SYMS" || fail "no __tsan_write1 in $BIN"
"$BIN" --help > "$WORK/help.log" 2>&1 || fail "TSan --help exited non-zero"
grep -q '^rn-impeller: sanitize_build=1 sanitizers=thread$' "$WORK/help.log" \
  || fail "binary did not print sanitizers=thread (not built with RNI_SANITIZE=thread)"
SYMBOLIZER="$(command -v llvm-symbolizer || ls /usr/bin/llvm-symbolizer-* 2>/dev/null | sort -V | tail -1)"
[ -n "$SYMBOLIZER" ] || fail "no llvm-symbolizer: reports would have no function names"
command -v xvfb-run >/dev/null || fail "xvfb-run is required for the windowed runs"
echo "instrumented: __tsan_init, sanitizers=thread, symbolizer $SYMBOLIZER"

# exitcode=0: a report must not end the run early; tsan_check.py reads every report file.
topts() { echo "log_path=$1/tsan exitcode=0 halt_on_error=0 history_size=4 external_symbolizer_path=$SYMBOLIZER suppressions=$ROOT/tools/sanitize/tsan_suppressions.txt"; }
want() { [ -z "${TSAN_RUNS:-}" ] || [[ " $TSAN_RUNS " == *" $1 "* ]]; }
RUNS=()

# One direct engine run. name mode(window|headless) bundle app frames [extra args...]
run() {
  local name="$1" mode="$2" bundle="$3" app="$4" frames="$5"; shift 5
  want "$name" || return 0
  local dir="$WORK/$name" rc; mkdir -p "$dir"
  local args=(--bundle "$ROOT/fixtures/$bundle" --app-name "$app" --width 400 --height 300
              --probe-banner off --supersample-rnsvg 0 --frames "$frames" "$@")
  if [ "$mode" = window ]; then
    ( cd "$(dirname "$BIN")" && TSAN_OPTIONS="$(topts "$dir")" timeout -k 10 600 \
        xvfb-run -a -s "-screen 0 1280x1024x24" "$BIN" --window --scale 1 "${args[@]}" ) > "$dir/run.log" 2>&1
  else
    ( cd "$(dirname "$BIN")" && TSAN_OPTIONS="$(topts "$dir")" timeout -k 10 600 \
        "$BIN" --headless "${args[@]}" --screenshot "$dir/frame.ppm" ) > "$dir/run.log" 2>&1
  fi
  rc=$?
  [ "$rc" = 0 ] || { tail -15 "$dir/run.log"; fail "$name exited rc=$rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$dir/run.log" || fail "$name mounted nothing (scene_nodes=0)"
  grep -q '\[js-exception\]' "$dir/run.log" && fail "$name: JS exception"
  RUNS+=("$dir")
  echo "ok $name ($(grep -m1 -o 'presents=[0-9]*' "$dir/run.log"))"
}

# An existing gate on the TSan binary (RNI_BIN), stamped like tools/ci-sanitize.sh.
gate() {
  local g="$1" name; name="gate-$(basename "$1" .sh)"
  want "$name" || return 0
  local dir="$WORK/$name"; mkdir -p "$dir/stamps"
  env RNI_BIN="$BIN" RNI_SANITIZE_STAMP_DIR="$dir/stamps" TSAN_OPTIONS="$(topts "$dir")" \
      timeout -k 1m 1h bash "$g" > "$dir/gate.log" 2>&1 \
    || { tail -15 "$dir/gate.log"; fail "$g failed under the TSan binary"; }
  [ "$(find "$dir/stamps" -type f | wc -l)" -gt 0 ] || fail "$g never ran the TSan binary (0 stamps)"
  RUNS+=("$dir")
  echo "ok $name runs=$(find "$dir/stamps" -type f | wc -l) ($(tail -1 "$dir/gate.log" | cut -c1-90))"
}

echo "== 3. fixtures on the TSan binary"
S=fp04-tsan/prebuilt/fp04-tsan.bundle
NT=native-transform/prebuilt/native-transform.bundle
AN=sc26-nw-animate/prebuilt/sc26-nw-animate.bundle
TX=eng22-font-family/prebuilt/eng22-font-family.bundle
IM=image-net/prebuilt/image-net.bundle
FONTS="$ROOT/fixtures/eng22-font-family/fonts"
wait_port() {  # port pid
  for _ in $(seq 50); do
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $1), 0.2)" 2>/dev/null && return 0
    kill -0 "$2" 2>/dev/null || fail "http server on $1 did not start (port busy?)"; sleep 0.1
  done; fail "http server on $1 not reachable"
}
# The stress fixture's <Image> fetches /churn.png?n=K: any path gets a 2x2 PNG, logged.
cat > "$WORK/churn_server.py" <<'PY'
import http.server, struct, sys, zlib
raw = b"\x00" + b"\x20\x80\x20" * 2
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
PNG = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw * 2)) + chunk(b"IEND", b""))
LOG = open(sys.argv[1], "a", buffering=1)
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def do_GET(self):
        LOG.write(self.path + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(PNG)))
        self.end_headers()
        self.wfile.write(PNG)
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", 18932), H).serve_forever()
PY
if want churn-window || want churn-headless; then
  : > "$WORK/churn_requests.log"
  python3 "$WORK/churn_server.py" "$WORK/churn_requests.log" > "$WORK/churn_server.out" 2>&1 & CHURN_PID=$!
  wait_port 18932 "$CHURN_PID"
fi
# --idle-skip is the windowed default for apps (no --frames); it reads the scene version on main.
run churn-window    window   "$S"  TsanTextChurn 600 --idle-skip
run churn-headless  headless "$S"  TsanTextChurn 60
if [ -n "$CHURN_PID" ]; then
  kill "$CHURN_PID" 2>/dev/null; wait "$CHURN_PID" 2>/dev/null; CHURN_PID=""
  nreq="$(sort -u "$WORK/churn_requests.log" | wc -l)"
  [ "$nreq" -ge 5 ] || fail "stress fixture fetched $nreq distinct image URLs (< 5): no off-thread image damage"
  echo "stress fixture image fetches: $nreq distinct URLs"
fi
run nt-window       window   "$NT" NativeRotateProbe 300
run nt-headless     headless "$NT" NativeOpacityPulse 31
run anim-window     window   "$AN" Sc26NwAnimate 300
run anim-headless   headless "$AN" Sc26NwAnimate 31
run text-window     window   "$TX" Eng22FontFamily 120 --font-dir "$FONTS"
run text-headless   headless "$TX" Eng22FontFamily 5 --font-dir "$FONTS"
# FP-12: regular / bold / custom-font / fallback-emoji text re-rendered every 4 ms; measure (js)
# and paint (main) each on their own typography context.
TY=fp12-typography/prebuilt/fp12-typography.bundle
run fp12-window     window   "$TY" Fp12Typography 600 --idle-skip --font-dir "$FONTS"
run fp12-headless   headless "$TY" Fp12Typography 60 --font-dir "$FONTS"
if want image-window || want image-headless; then
  # The image fixture fetches from ci-image-net.sh's local server: reuse that server verbatim.
  sed -n "/^cat > \"\$WORK\/server.py\" <<'PY'\$/,/^PY\$/p" tools/ci-image-net.sh | sed '1d;$d' > "$WORK/server.py"
  grep -q 'ThreadingHTTPServer(("127.0.0.1", 18931)' "$WORK/server.py" || fail "could not extract the image server from tools/ci-image-net.sh"
  python3 "$WORK/server.py" "$WORK/requests.log" > "$WORK/server.out" 2>&1 & SERVER_PID=$!
  wait_port 18931 "$SERVER_PID"
  # --idle-skip: the fetch thread bumps the scene version (image damage wake) while main reads it.
  run image-window   window   "$IM" probe 120 --idle-skip
  run image-headless headless "$IM" probe 5
  kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
  [ -s "$WORK/requests.log" ] || fail "image runs made no HTTP requests"
fi
gate tools/ci-text.sh
gate tools/ci-native-transform.sh
gate tools/ci-image-net.sh
gate tools/ci-image-io.sh   # FP-16: IO pool, cancel, dedup
[ "${#RUNS[@]}" -gt 0 ] || fail "no runs selected (TSAN_RUNS=${TSAN_RUNS:-})"

echo "== 4. reports"
python3 tools/tsan_check.py tools/sanitize/tsan_known.txt "${RUNS[@]}" > "$WORK/check.txt" 2>&1; rc=$?
cat "$WORK/check.txt"
[ "$rc" = 0 ] || fail "$(grep -m1 '^TSAN_CHECK_FAIL' "$WORK/check.txt" | cut -c17-)"
echo "TSAN_PASS (${#RUNS[@]} runs, 0 new race reports; known: $(grep '^known ' "$WORK/check.txt" | cut -d' ' -f2,7 | tr '\n' ' '))"
