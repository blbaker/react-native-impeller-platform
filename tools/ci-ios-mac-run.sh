#!/usr/bin/env bash
# iOS gate: the iPhone build of the engine RUNS, on an Apple-silicon Mac, as
# an iOS app ("My Mac (Designed for iPad)"), drawing on the real GPU. Builds
# the test host's Xcode project (tools/ios-xcode-project.sh) for iphoneos with
# Xcode's automatic signing, in the logged-in GUI session (tools/lib/
# mac-gui-job.sh: codesign cannot reach the keychain from SSH), installs it in
# the App Store wrapper layout, launches it on the M1 smoke fixture, then
# reads its log. Needs: someone logged in at the Mac, an "Apple Development"
# certificate, and the iOS development profile Xcode makes on the first run
# for "My Mac (Designed for iPad)" (docs/eng/ios-platform.md).
#   bash tools/ci-ios-mac-run.sh   (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
# Arms (each failure prints `IOS_MAC_RUN_GATE FAIL <arm>: ...`):
#   S  signed for this Mac: xcodebuild succeeded in the GUI session; the app is
#      signed by an Apple Development identity and embeds a provisioning
#      profile that covers this Mac
#   L  launched: the RniTestHost process runs, and its binary is Mach-O
#      platform IOS arm64 (the iPhone build, not the Simulator's)
#   E  the engine draws on real Metal: it booted, the Metal device is not a
#      Simulator one, a first frame presented, and frames keep presenting
#      (>= 100 more over 3 s)
# Pass line: IOS_MAC_RUN_PASS (device=<gpu> frames_in_3s=<n>, in steps of 60:
# the app logs every 60 frames).
# Mutants: tools/mutation-verify-ios-mac-run.sh. RNI_MAC_RUN_ADHOC=1 signs
# ad hoc instead (mutant M2; measured: xcodebuild already refuses to build it
# for this destination, so it fails S).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/mac-gui-job.sh"
ios_begin ios-mac-run
FAILS=()
bad() { echo "IOS_MAC_RUN_GATE FAIL $1: $2"; FAILS+=("$1"); }
BID=dev.rnimpeller.testhost
DD="$HOME/Library/Caches/rni-ios-ci/xcode-dd-mac"
X="$IOS_ROOT/engine/ios/testhost/xcode"
quit_app() { pkill -x RniTestHost 2> /dev/null; sleep 1; }

bash tools/engine-build-ios.sh device > "$IOS_WORK/engine-build.log" 2>&1 \
  || { tail -20 "$IOS_WORK/engine-build.log"; echo "IOS_MAC_RUN_FAIL (engine build)"; exit 1; }
bash tools/ios-xcode-project.sh > "$IOS_WORK/xcodeproj.log" 2>&1 \
  || { tail -5 "$IOS_WORK/xcodeproj.log"; echo "IOS_MAC_RUN_FAIL (xcode project)"; exit 1; }
quit_app

echo "== S: build + sign in the GUI session =="
# This Mac as the "Designed for iPad" destination, by id: the variant name
# itself ("Designed for [iPad,iPhone]") has a comma -destination cannot parse.
MAC=$(system_profiler SPHardwareDataType 2> /dev/null | sed -nE 's/.*Provisioning UDID: (.*)/\1/p')
SIGN=()
[ "${RNI_MAC_RUN_ADHOC:-0}" = 1 ] && SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
cat > "$IOS_WORK/build.sh" << SH
set -o pipefail
echo "session: \$(launchctl managername)"
xcodebuild -project "$X/RniTestHost.xcodeproj" -scheme RniTestHost -configuration Debug \\
  -destination "platform=macOS,id=$MAC" \\
  -derivedDataPath "$DD" \${RNI_MAC_RUN_PROVISION_UPDATES:+-allowProvisioningUpdates} ${SIGN[*]+${SIGN[*]}} build > "$IOS_WORK/xcodebuild.log" 2>&1
rc=\$?
echo "xcodebuild rc=\$rc"
exit \$rc
SH
mac_gui_run "$IOS_WORK/build.sh" "$IOS_WORK/build-job.log" 900
BRC=$?
cat "$IOS_WORK/build-job.log"
[ "$BRC" = 0 ] || { grep -E 'error:|Signing|provisioning' "$IOS_WORK/xcodebuild.log" | head -6; bad S "xcodebuild in the GUI session failed (rc=$BRC)"; }
APP="$DD/Build/Products/Debug-iphoneos/RniTestHost.app"
if [ -d "$APP" ] && [ "$BRC" = 0 ]; then
  AUTH=$(codesign -dvv "$APP" 2>&1 | sed -nE 's/^Authority=(Apple Development[^)]*\)).*/\1/p' | head -1)
  echo "signed by: ${AUTH:-ad hoc / none}"
  if [ "${RNI_MAC_RUN_ADHOC:-0}" != 1 ]; then
    [ -n "$AUTH" ] || bad S "the app is not signed by an Apple Development identity"
    if [ -f "$APP/embedded.mobileprovision" ]; then
      security cms -D -i "$APP/embedded.mobileprovision" > "$IOS_WORK/profile.plist" 2> /dev/null
      PNAME=$(/usr/libexec/PlistBuddy -c 'Print :Name' "$IOS_WORK/profile.plist" 2> /dev/null)
      COVERS=$(/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$IOS_WORK/profile.plist" 2> /dev/null | grep -c "$MAC")
      echo "profile: $PNAME (covers this Mac: $COVERS)"
      [ "$COVERS" -ge 1 ] || bad S "the embedded profile does not cover this Mac"
    else
      bad S "no embedded.mobileprovision"
    fi
  fi
fi

echo "== L: launch on the Mac =="
WRAP="$IOS_WORK/install/RniTestHost.app"
if [ -d "$APP" ]; then
  mkdir -p "$WRAP/Wrapper" && cp -R "$APP" "$WRAP/Wrapper/" && ln -s Wrapper/RniTestHost.app "$WRAP/WrappedBundle"
  touch "$IOS_WORK/launched.marker"
  cat > "$IOS_WORK/launch.sh" << SH
open -n "$WRAP" --args --test=engine --bundle=ios-smoke.jsbundle --app=IosSmoke --log-file=1
echo "open rc=\$?"
SH
  mac_gui_run "$IOS_WORK/launch.sh" "$IOS_WORK/launch-job.log" 60
  cat "$IOS_WORK/launch-job.log"
  PID=""
  for _ in $(seq 1 40); do PID=$(pgrep -x RniTestHost | head -1); [ -n "$PID" ] && break; sleep 0.5; done
  if [ -n "$PID" ]; then
    EXE=$(ps -o comm= -p "$PID")
    PLAT=$(vtool -show-build "$EXE" 2> /dev/null | awk '/platform/{print $2; exit}')
    echo "running: pid $PID, platform $PLAT, $(lipo -archs "$EXE" 2> /dev/null)"
    [ "$PLAT" = IOS ] || bad L "the running binary is platform ${PLAT:-?}, not IOS"
  else
    bad L "RniTestHost never started: $(log show --last 30s --style compact --predicate 'process == "MobileInstallationHelperService" OR eventMessage CONTAINS "RniTestHost"' 2> /dev/null | grep -iE 'fail|denied|invalid|signature' | head -2 | cut -c1-200)"
  fi
else
  bad L "no built app at $APP"
fi

echo "== E: the engine on real Metal =="
LOG=""
if [ -n "${PID:-}" ]; then
  for _ in $(seq 1 60); do
    LOG=$(find "$HOME/Library/Containers" -maxdepth 5 -name testhost.log -newer "$IOS_WORK/launched.marker" 2> /dev/null | head -1)
    [ -n "$LOG" ] && grep -q 'rni-ios: engine first_frame' "$LOG" && break
    sleep 0.5
  done
fi
if [ -n "$LOG" ]; then
  cp "$LOG" "$IOS_WORK/app.log"
  grep -E 'metal_layer|engine booted|first_frame' "$LOG" | head -3
  DEV=$(sed -nE 's/.*metal_layer .*device=(.*)$/\1/p' "$LOG" | head -1)
  grep -q 'rni-ios: engine booted .* js_idle_after_eval=1 js_idle_after_start=1' "$LOG" || bad E "the engine did not boot"
  grep -q 'rni-ios: engine first_frame' "$LOG" || bad E "no first frame"
  [ -n "$DEV" ] && ! echo "$DEV" | grep -qi simulator || bad E "Metal device is '${DEV:-none}'"
  N1=$(sed -nE 's/.*engine presented=([0-9]+).*/\1/p' "$LOG" | tail -1); sleep 3
  N2=$(sed -nE 's/.*engine presented=([0-9]+).*/\1/p' "$LOG" | tail -1)
  # The app logs every 60 frames, so this is in steps of 60.
  FRAMES3=$(( ${N2:-0} - ${N1:-0} ))
  echo "presented ${N1:-?} -> ${N2:-?} over 3 s"
  [ $(( ${N2:-0} - ${N1:-0} )) -ge 100 ] || bad E "only $(( ${N2:-0} - ${N1:-0} )) frames presented in 3 s"
else
  bad E "no app log with a first frame"
fi
ios_keep "$IOS_WORK/app.log" "$IOS_WORK/xcodebuild.log" 2> /dev/null
quit_app

[ "${#FAILS[@]}" = 0 ] || { echo "IOS_MAC_RUN_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_MAC_RUN_PASS (device=$DEV frames_in_3s=$FRAMES3)"
