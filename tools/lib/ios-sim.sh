# shellcheck shell=bash
# iOS Phase 1: the shared harness every tools/ci-*-ios*.sh gate sources.
#
# A gate runs ON a Mac (Xcode + the iOS Simulator). Started on linux with
# RNI_MAC_HOST=<ssh host> set, it re-execs itself there through
# tools/mac-run.sh (a hash-verified copy of this worktree in RNI_MAC_TREE,
# default rni-ios); without RNI_MAC_HOST it exits 2 (not a pass, not a fail).
#
# On the Mac it builds the test host (engine/ios/testhost + the iOS sources
# under test) with xcrun clang++ against the iOS Simulator Impeller SDK, boots a
# FRESH simulator (deleted on exit), installs and launches the host with
# --test=<name>. The app's stdout lands in a log the gate greps.
#
#   ios_on_mac_or_reexec "$0" "$@"   first line of every gate
#   ios_begin <gate-name>            work dir $IOS_WORK, EXIT trap (sim deleted)
#   ios_build_testhost               -> $IOS_APP
#   ios_sim_up                       -> $IOS_UDID (booted, settled, host installed)
#   ios_launch <log> <test> [args]   relaunch the host; stdout -> <log>
#   ios_wait_log <log> <ERE> <sec>   0 once a line matches
#   ios_screenshot <png>, ios_container (the app's data dir), ios_keep <file>
IOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS_BID=dev.rnimpeller.testhost
IOS_UDID=""
# The iOS sources under test plus the host. One list for every gate: a gate
# that passes builds exactly what the other gates build.
IOS_SRCS=(
  engine/ios/testhost/TestHostApp.mm
  engine/ios/testhost/TestHostMetal.mm
  engine/ios/testhost/TestHostVsync.mm
  engine/ios/testhost/TestHostLifecycle.mm
  engine/ios/testhost/TestHostSettings.mm
  engine/ios/testhost/TestHostClipboard.mm
  engine/host/MetalSurfaceIOS.mm
  engine/host/DisplayLinkIOS.mm
  engine/host/GpuAvailabilityIOS.mm
  engine/host/OsAppearanceIOS.mm
  engine/modules/AccessibilitySettingsIOS.mm
  engine/modules/ClipboardIOS.mm
  engine/base/GpuAvailability.cpp
  engine/host/OsAppearance.cpp
  engine/host/Pixel.cpp
)

ios_on_mac_or_reexec() {
  [ "$(uname -s)" = Darwin ] && return 0
  local rel="${1#"$IOS_ROOT"/}"; shift
  rel="${rel#./}"
  if [ -z "${RNI_MAC_HOST:-}" ]; then
    echo "ios-sim: $rel needs macOS with Xcode and the iOS Simulator."
    echo "ios-sim: from linux, set RNI_MAC_HOST=<ssh host of a Mac> to run it there."
    exit 2
  fi
  # Only these knobs cross over; everything else a gate needs is in the tree.
  RNI_MAC_TREE="${RNI_MAC_TREE:-rni-ios}" \
    RNI_MAC_ENV="IOS_DEVICE IOS_SETTLE IOS_KEEP_SIM RNI_IOS_SDK RNI_IOS_CI_DIR IOS_SIM_SHOT_EARLY IOS_INPUT_TEST" \
    exec bash "$IOS_ROOT/tools/mac-run.sh" bash "$rel" "$@"
}

ios_cleanup() {
  if [ -n "$IOS_UDID" ] && [ "${IOS_KEEP_SIM:-0}" != 1 ]; then
    xcrun simctl shutdown "$IOS_UDID" > /dev/null 2>&1
    xcrun simctl delete "$IOS_UDID" > /dev/null 2>&1
  fi
  [ -n "${IOS_WORK:-}" ] && rm -rf "$IOS_WORK"
}

ios_begin() {
  IOS_GATE="$1"
  # Under $HOME, not $TMPDIR: a simulator app's --stdout file under
  # /var/folders stays empty (measured), the same file under $HOME fills.
  local base="${RNI_IOS_CI_DIR:-$HOME/Library/Caches/rni-ios-ci}"
  mkdir -p "$base/work"
  IOS_WORK="$(mktemp -d "$base/work/$1.XXXXXX")"
  IOS_ART="$base/artifacts/$1"   # last run's evidence, kept
  rm -rf "$IOS_ART" && mkdir -p "$IOS_ART"
  trap ios_cleanup EXIT
  cd "$IOS_ROOT" || exit 1
}

ios_keep() { cp "$@" "$IOS_ART/" 2> /dev/null || true; }

# RNI_IOS_SDK: a dir with include/impeller.h + lib/libimpeller.a for the iOS
# Simulator (arm64). Default: the one tools/sdk-fetch-ios.sh stages on the Mac.
ios_sdk_resolve() {
  local d="${RNI_IOS_SDK:-$IOS_ROOT/engine/third_party/impeller-sdk-ios-simulator-arm64}"
  if [ -f "$d/include/impeller.h" ] && [ -f "$d/lib/libimpeller.a" ]; then
    IOS_SDK_INC="$d/include" IOS_SDK_LIB="$d/lib/libimpeller.a"
    return 0
  fi
  echo "ios-sim: no iOS Simulator Impeller SDK at $d (run tools/sdk-fetch-ios.sh)"
  return 1
}

# ios_build_testhost            the Phase 1 host: IOS_SRCS compiled in.
# ios_build_testhost engine     the engine host: the test host sources plus
#   TestHostEngine.mm, linked against librni_ios_all.a (tools/engine-build-ios.sh,
#   RNI_IOS_ENGINE_LIB) instead of IOS_SRCS, hermesvm.framework embedded, and
#   the fixture bundles in IOS_BUNDLES copied in as <name>.jsbundle.
IOS_BUNDLES=(fixtures/ios-smoke/prebuilt/ios-smoke.bundle fixtures/ios-input/prebuilt/ios-input.bundle)
ios_build_testhost() {
  ios_sdk_resolve || return 1
  IOS_APP="$IOS_WORK/RniTestHost.app"
  rm -rf "$IOS_APP" && mkdir -p "$IOS_APP"
  local t0=$SECONDS srcs=("${IOS_SRCS[@]}") link=() what="${#IOS_SRCS[@]} sources"
  if [ "${1:-}" = engine ]; then
    local lib="${RNI_IOS_ENGINE_LIB:-$IOS_ROOT/engine/build-ios-simulator/librni_ios_all.a}"
    local hx="$IOS_ROOT/engine/third_party/hermes-ios"
    local fw
    fw="$(ls -d "$hx"/hermesvm.xcframework/ios-*simulator 2> /dev/null | head -1)"
    [ -f "$lib" ] || { echo "ios-sim: no engine library at $lib (run tools/engine-build-ios.sh)"; return 1; }
    [ -d "$fw/hermesvm.framework" ] || { echo "ios-sim: no hermesvm.framework under $hx (run tools/hermes-build-ios.sh)"; return 1; }
    srcs=()
    local f
    for f in engine/ios/testhost/*.mm; do srcs+=("$f"); done
    mkdir -p "$IOS_APP/Frameworks"
    cp -R "$fw/hermesvm.framework" "$IOS_APP/Frameworks/"
    for f in "${IOS_BUNDLES[@]}"; do cp "$f" "$IOS_APP/$(basename "$f" .bundle).jsbundle"; done
    link=("$lib" -F "$fw" -framework hermesvm -Wl,-rpath,@executable_path/Frameworks)
    what="engine host, ${lib#"$IOS_ROOT"/} $(du -h "$lib" | cut -f1)"
  fi
  if ! xcrun --sdk iphonesimulator clang++ -std=c++20 -fobjc-arc -target arm64-apple-ios15.1-simulator \
      -Wall -Wextra -Wno-unused-parameter -Werror \
      -I engine -I engine/ios/testhost -isystem "$IOS_SDK_INC" "${srcs[@]}" ${link[@]+"${link[@]}"} "$IOS_SDK_LIB" \
      -framework UIKit -framework Metal -framework MetalPerformanceShaders -framework QuartzCore \
      -framework CoreGraphics -framework CoreText -framework Foundation \
      -o "$IOS_APP/RniTestHost" > "$IOS_WORK/build.log" 2>&1; then
    echo "ios-sim: testhost build FAILED:"; grep -m12 -E 'error|warning|Undefined|referenced from' "$IOS_WORK/build.log"
    return 1
  fi
  cp engine/ios/testhost/Info.plist "$IOS_APP/Info.plist"
  if [ -d "$IOS_APP/Frameworks" ]; then
    codesign --force --sign - --timestamp=none "$IOS_APP"/Frameworks/*.framework > "$IOS_WORK/sign.log" 2>&1 \
      || { echo "ios-sim: codesign (frameworks) FAILED: $(cat "$IOS_WORK/sign.log")"; return 1; }
  fi
  codesign --force --sign - --timestamp=none "$IOS_APP" > "$IOS_WORK/sign.log" 2>&1 \
    || { echo "ios-sim: codesign FAILED: $(cat "$IOS_WORK/sign.log")"; return 1; }
  echo "ios-sim: testhost built in $((SECONDS - t0))s ($(du -sh "$IOS_APP" | cut -f1), $what, sdk ${IOS_SDK_LIB#"$HOME"/})"
}

ios_sim_up() {
  local rt dt old
  # Leftovers of a killed run (shut down, never deleted). Booted ones may be
  # another gate's: left alone.
  for old in $(xcrun simctl list devices | sed -nE 's/.*rni-ci-[^ ]* \(([0-9A-F-]{36})\) \(Shutdown\).*/\1/p'); do
    xcrun simctl delete "$old" > /dev/null 2>&1
  done
  rt=$(xcrun simctl list runtimes available | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+' | sort -V | tail -1)
  dt="com.apple.CoreSimulator.SimDeviceType.${IOS_DEVICE:-iPhone-16}"
  IOS_UDID=$(xcrun simctl create "rni-ci-$IOS_GATE" "$dt" "$rt" 2> "$IOS_WORK/sim.log") \
    || { echo "ios-sim: simctl create FAILED: $(cat "$IOS_WORK/sim.log")"; return 1; }
  xcrun simctl boot "$IOS_UDID" >> "$IOS_WORK/sim.log" 2>&1 \
    && xcrun simctl bootstatus "$IOS_UDID" -b >> "$IOS_WORK/sim.log" 2>&1 \
    || { echo "ios-sim: boot FAILED: $(tail -3 "$IOS_WORK/sim.log")"; return 1; }
  # A fresh simulator posts first-boot banners over the foreground app.
  sleep "${IOS_SETTLE:-10}"
  xcrun simctl install "$IOS_UDID" "$IOS_APP" >> "$IOS_WORK/sim.log" 2>&1 \
    || { echo "ios-sim: install FAILED: $(tail -3 "$IOS_WORK/sim.log")"; return 1; }
  echo "ios-sim: simulator ${dt##*.} ${rt##*.} $IOS_UDID"
}

ios_launch() {
  local log="$1" test="$2"
  shift 2
  : > "$log"
  : > "$log.err"   # simctl --stdout appends
  xcrun simctl launch --terminate-running-process --stdout="$log" --stderr="$log.err" \
    "$IOS_UDID" "$IOS_BID" "--test=$test" "$@" > /dev/null
}

ios_wait_log() {
  local i=0 n=$(($3 * 4))
  while [ $i -lt $n ]; do
    grep -qE "$2" "$1" 2> /dev/null && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

ios_screenshot() { xcrun simctl io "$IOS_UDID" screenshot --type=png "$1" > /dev/null 2>&1; }
ios_container() { xcrun simctl get_app_container "$IOS_UDID" "$IOS_BID" data; }
# Value of key=<v> on the first log line matching <ERE>.
ios_kv() { grep -m1 -E "$2" "$1" | sed -nE "s/.*[ ]$3=([^ ]+).*/\1/p"; }
