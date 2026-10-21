#!/usr/bin/env bash
# Generate engine/ios/testhost/xcode/RniTestHost.xcodeproj (XcodeGen) so the
# engine test host can be run from Xcode: on an iPhone/iPad, or on an
# Apple-silicon Mac as "My Mac (Designed for iPad)". Xcode's automatic signing
# then makes the provisioning profile; nothing here signs anything.
#   bash tools/ios-xcode-project.sh [--build]  (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
# --build also builds the project for iphoneos and the Simulator with signing
# off (a link check; the Xcode-built app is otherwise the same as the gates').
# Env: RNI_IOS_TEAM (default: see "The team" below), RNI_IOS_BUNDLE_ID (default
# dev.rnimpeller.testhost). Needs xcodegen (brew install xcodegen), the
# device and Simulator engine builds and Impeller SDKs, and Hermes for iOS.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
export PATH="/opt/homebrew/bin:$PATH"
cd "$IOS_ROOT"
X=engine/ios/testhost/xcode
command -v xcodegen > /dev/null || { echo "ios-xcode-project: needs xcodegen (brew install xcodegen)"; exit 1; }
for f in engine/build-ios-device/librni_ios_all.a engine/build-ios-simulator/librni_ios_all.a \
         engine/third_party/impeller-sdk-ios-arm64/lib/libimpeller.a \
         engine/third_party/impeller-sdk-ios-simulator-arm64/lib/libimpeller.a \
         engine/third_party/hermes-ios/hermesvm.xcframework/Info.plist; do
  [ -e "$f" ] || { echo "ios-xcode-project: missing $f (tools/engine-build-ios.sh, tools/sdk-fetch-ios.sh, tools/hermes-build-ios.sh)"; exit 1; }
done
# The team: RNI_IOS_TEAM, else the team of a local iOS development profile that
# covers this Mac (the one Xcode made on a "My Mac (Designed for iPad)" run:
# that team can sign without the developer portal), else the team on the first
# "Apple Development" certificate. A Mac can hold several teams' certificates,
# and only some may be able to make profiles (an unaccepted program license
# agreement blocks a team: "PLA Update available").
TEAM_FROM=env
if [ -z "${RNI_IOS_TEAM:-}" ]; then
  MAC=$(system_profiler SPHardwareDataType 2> /dev/null | sed -nE 's/.*Provisioning UDID: (.*)/\1/p')
  for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
    [ -f "$f" ] || continue
    p=$(security cms -D -i "$f" 2> /dev/null) || continue
    echo "$p" | plutil -extract Platform json -o - - 2> /dev/null | grep -q '"iOS"' || continue
    echo "$p" | plutil -extract ProvisionedDevices json -o - - 2> /dev/null | grep -q "$MAC" || continue
    [ "$(echo "$p" | plutil -extract ExpirationDate raw -o - - 2> /dev/null | cut -c1-10)" \> "$(date -u +%Y-%m-%d)" ] || continue
    RNI_IOS_TEAM=$(echo "$p" | plutil -extract TeamIdentifier.0 raw -o - - 2> /dev/null) && TEAM_FROM=profile && break
  done
fi
if [ -z "${RNI_IOS_TEAM:-}" ]; then
  RNI_IOS_TEAM=$(security find-certificate -a -c "Apple Development" -p 2> /dev/null \
    | openssl x509 -noout -subject 2> /dev/null | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' | head -1)
  TEAM_FROM=certificate
fi
[ -n "${RNI_IOS_TEAM:-}" ] || { echo "ios-xcode-project: no team: set RNI_IOS_TEAM"; exit 1; }
export RNI_IOS_TEAM RNI_IOS_BUNDLE_ID="${RNI_IOS_BUNDLE_ID:-dev.rnimpeller.testhost}"
rm -rf "$X/Bundles" && mkdir -p "$X/Bundles"
for f in "${IOS_BUNDLES[@]}"; do cp "$f" "$X/Bundles/$(basename "$f" .bundle).jsbundle"; done
(cd "$X" && xcodegen generate --spec project.yml --quiet) || { echo "ios-xcode-project: xcodegen failed"; exit 1; }
echo "ios-xcode-project: $X/RniTestHost.xcodeproj (team from $TEAM_FROM, bundle id $RNI_IOS_BUNDLE_ID)"
[ "${1:-}" = --build ] || exit 0
for sdk in iphoneos iphonesimulator; do
  log="$HOME/Library/Caches/rni-ios-ci/xcode-$sdk.log"
  mkdir -p "$(dirname "$log")"
  if xcodebuild -project "$X/RniTestHost.xcodeproj" -scheme RniTestHost -sdk "$sdk" -configuration Debug \
       -derivedDataPath "$HOME/Library/Caches/rni-ios-ci/xcode-dd" CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1; then
    app=$(ls -d "$HOME"/Library/Caches/rni-ios-ci/xcode-dd/Build/Products/Debug-"$sdk"/RniTestHost.app)
    echo "ios-xcode-project: $sdk build OK ($(vtool -show-build "$app/RniTestHost" | awk '/platform/{print $2; exit}'), $(du -sh "$app" | awk '{print $1}'))"
  else
    echo "ios-xcode-project: $sdk build FAILED"; grep -E 'error:|Undefined|ld: ' "$log" | head -10; exit 1
  fi
done
echo "IOS_XCODE_PROJECT_OK"
