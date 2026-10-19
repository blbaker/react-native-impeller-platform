# shellcheck shell=bash
# iOS Phase 4 spike: XCUITest without an Xcode project, for gates that need
# REAL UIKit input (taps through the simulator's touch system, the software
# keyboard). Sourced after tools/lib/ios-sim.sh, on the Mac.
#
#   ios_build_uitest <src.m> <Name>   -> $IOS_WORK/<Name>-Runner.app (Xcode's own
#       XCTRunner.app template) with PlugIns/<Name>.xctest built from <src.m>
#   ios_run_uitest <Name> <log> KEY=VALUE...   writes $IOS_WORK/<Name>.xctestrun
#       (man 5 xcodebuild.xctestrun, FormatVersion 2) with the KEY=VALUEs as the
#       runner's environment, then `xcodebuild test-without-building` on
#       $IOS_UDID. The UI target app is $IOS_APP (ios_build_testhost). rc = xcodebuild's.
IOS_XC_PLATFORM="$(xcode-select -p 2> /dev/null)/Platforms/iPhoneSimulator.platform/Developer"

ios_build_uitest() {
  local src="$1" name="$2" runner bundle
  runner="$IOS_WORK/$name-Runner.app"
  bundle="$runner/PlugIns/$name.xctest"
  rm -rf "$runner"
  cp -R "$IOS_XC_PLATFORM/Library/Xcode/Agents/XCTRunner.app" "$runner" || return 1
  # The template's Info.plist carries Xcode build-setting placeholders.
  plutil -replace CFBundleExecutable -string XCTRunner "$runner/Info.plist"
  plutil -replace CFBundleIdentifier -string "dev.rnimpeller.$name.xctrunner" "$runner/Info.plist"
  plutil -replace CFBundleName -string "$name-Runner" "$runner/Info.plist"
  mkdir -p "$bundle"
  if ! xcrun --sdk iphonesimulator clang -fobjc-arc -fmodules -target arm64-apple-ios15.1-simulator \
      -bundle -F "$IOS_XC_PLATFORM/Library/Frameworks" -framework XCTest -framework XCUIAutomation \
      -framework UIKit -framework Foundation "$src" -o "$bundle/$name" > "$IOS_WORK/uitest-build.log" 2>&1; then
    echo "ios-uitest: build FAILED:"; grep -m8 -E 'error|warning' "$IOS_WORK/uitest-build.log"
    return 1
  fi
  cat > "$bundle/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>dev.rnimpeller.$name</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>MinimumOSVersion</key><string>15.1</string>
</dict></plist>
PLIST
  codesign --force --sign - --timestamp=none "$bundle" > "$IOS_WORK/uitest-sign.log" 2>&1 \
    && codesign --force --sign - --timestamp=none "$runner" >> "$IOS_WORK/uitest-sign.log" 2>&1 \
    || { echo "ios-uitest: codesign FAILED: $(cat "$IOS_WORK/uitest-sign.log")"; return 1; }
  echo "ios-uitest: built $name-Runner.app ($(du -sh "$runner" | cut -f1))"
}

ios_run_uitest() {
  local name="$1" log="$2" kv envs=""
  shift 2
  for kv in "$@"; do
    envs="$envs<key>${kv%%=*}</key><string>${kv#*=}</string>"
  done
  local fw="__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks"
  local pfw="__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/PrivateFrameworks"
  local lib="__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib"
  cat > "$IOS_WORK/$name.xctestrun" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>TestConfigurations</key><array><dict>
    <key>Name</key><string>Default</string>
    <key>TestTargets</key><array><dict>
      <key>BlueprintName</key><string>$name</string>
      <key>ProductModuleName</key><string>$name</string>
      <key>IsUITestBundle</key><true/>
      <key>IsXCTRunnerHostedTestBundle</key><true/>
      <key>TestBundlePath</key><string>__TESTHOST__/PlugIns/$name.xctest</string>
      <key>TestHostPath</key><string>__TESTROOT__/$name-Runner.app</string>
      <key>TestHostBundleIdentifier</key><string>dev.rnimpeller.$name.xctrunner</string>
      <key>UITargetAppPath</key><string>__TESTROOT__/$(basename "$IOS_APP")</string>
      <key>DependentProductPaths</key><array>
        <string>__TESTROOT__/$(basename "$IOS_APP")</string>
        <string>__TESTROOT__/$name-Runner.app</string>
        <string>__TESTROOT__/$name-Runner.app/PlugIns/$name.xctest</string>
      </array>
      <key>EnvironmentVariables</key><dict>$envs</dict>
      <key>TestingEnvironmentVariables</key><dict>
        <key>DYLD_FRAMEWORK_PATH</key><string>$fw:$pfw</string>
        <key>DYLD_LIBRARY_PATH</key><string>$lib</string>
      </dict>
      <key>SystemAttachmentLifetime</key><string>keepNever</string>
      <key>UserAttachmentLifetime</key><string>keepNever</string>
    </dict></array>
  </dict></array>
  <key>__xctestrun_metadata__</key><dict><key>FormatVersion</key><integer>2</integer></dict>
</dict></plist>
PLIST
  plutil -lint "$IOS_WORK/$name.xctestrun" > /dev/null || { echo "ios-uitest: bad xctestrun"; return 1; }
  xcodebuild test-without-building -xctestrun "$IOS_WORK/$name.xctestrun" \
    -destination "id=$IOS_UDID" -resultBundlePath "$IOS_WORK/$name.xcresult" > "$log" 2>&1
}
