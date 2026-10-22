#!/usr/bin/env bash
# iOS gate: an expo-blur <BlurView> re-blurs content that moves beneath it.
# The iOS half of tools/ci-blur-scroll.sh, same fixture (fixtures/blur-scroll)
# and same pixel verdict (tools/blur_scroll_compare.py), from simulator
# screenshots. RNIEngine repaints every frame in full (no partial repaint on
# iOS), so this is the M + S proof that the blur follows the content; the
# desktop gate also covers the partial-repaint readback case.
#   bash tools/ci-ios-blur-scroll.sh   (on linux: RNI_MAC_HOST=<ssh host> runs it on a Mac)
# Arms (each failure prints `IOS_BLUR_SCROLL FAIL <arm>: ...`):
#   M  the header's pixels change as the tiles scroll under it (offset 0 -> 100)
#      and as the tile under it changes colour
#   S  after the motion the screen equals the same scene painted in its end
#      state from the start (BlurScrollStatic / BlurTileStatic)
# Pass line: IOS_BLUR_SCROLL_PASS.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-sim.sh"
ios_on_mac_or_reexec "$0" "$@"
ios_begin ios-blur-scroll
FAILS=()
bad() { echo "IOS_BLUR_SCROLL FAIL $1: $2"; FAILS+=("$1"); }
bash tools/engine-build-ios.sh simulator > "$IOS_WORK/engine-build.log" 2>&1 \
  || { tail -25 "$IOS_WORK/engine-build.log"; echo "IOS_BLUR_SCROLL_FAIL (engine build)"; exit 1; }
ios_build_testhost engine || { echo "IOS_BLUR_SCROLL_FAIL (test host build)"; exit 1; }
ios_sim_up || { echo "IOS_BLUR_SCROLL_FAIL (simulator)"; exit 1; }

# shoot <tag> <app> <line ERE>...: launch, and per ERE wait for it, 0.5 s, screenshot <tag>-<k>.png
shoot() {
  local tag="$1" app="$2" k=0
  shift 2
  local log="$IOS_WORK/$tag.log"
  ios_launch "$log" engine --bundle=blur-scroll.jsbundle "--app=$app" || { bad setup "$tag: launch"; return 1; }
  # The scene's own ready line waits for frames too; this is belt and braces.
  ios_wait_log "$log" 'rni-ios: engine first_frame ' 60 || { bad setup "$tag: no first frame"; return 1; }
  for pat in "$@"; do
    k=$((k + 1))
    ios_wait_log "$log" "$pat" 40 || { bad setup "$tag: no '$pat': $(tail -2 "$log" | tr '\n' ' ')"; return 1; }
    sleep 0.5
    ios_screenshot "$IOS_WORK/$tag-$k.png" || { bad setup "$tag: screenshot $k"; return 1; }
  done
  ios_keep "$log" "$IOS_WORK/$tag-"*.png
}
# A simulator posts system banners ("Ready for Apple Intelligence") over the
# foreground app at times of its own choosing, well after the boot settle.
# A banner-covered shot fails S, so each scene gets up to 3 attempts (both apps
# relaunched, every retake logged); a blur that does not follow its content
# fails all three. Same rule as the other iOS screenshot gates.
SCALE=""
scene_check() {  # scene motion-app static-app
  local scene="$1" mapp="$2" sapp="$3" try outp
  for try in 1 2 3; do
    shoot "$scene-m$try" "$mapp" 'BLURSCROLL ready' 'BLURSCROLL done' || return 1
    shoot "$scene-s$try" "$sapp" 'BLURSCROLL ready' || return 1
    [ -n "$SCALE" ] || SCALE=$(sed -nE 's/.*testhost: engine uikit_points=[0-9]+x[0-9]+ uikit_scale=([0-9.]+).*/\1/p' "$IOS_WORK/$scene-m$try.log" | head -1)
    [ -n "$SCALE" ] || { bad setup "no uikit_scale line"; return 1; }
    outp=$(python3 tools/blur_scroll_compare.py "$scene" "$SCALE" "$IOS_WORK/$scene-m$try-1.png" \
      "$IOS_WORK/$scene-m$try-2.png" "$IOS_WORK/$scene-s$try-1.png")
    echo "$outp" | sed "s/^/[$scene try $try] /"
    echo "$outp" | grep -q '^FAIL' || return 0
    [ "$try" = 3 ] || echo "[$scene try $try] failed; retaking (a system banner can cover a shot)"
  done
  while IFS= read -r l; do case "$l" in FAIL\ *) l="${l#FAIL }"; bad "${l%%:*}" "${l#*: }" ;; esac; done <<< "$outp"
  return 1
}
scene_check scroll BlurScrollMotion BlurScrollStatic
scene_check tile BlurTileChange BlurTileStatic
xcrun simctl terminate "$IOS_UDID" "$IOS_BID" > /dev/null 2>&1 || true
[ "${#FAILS[@]}" = 0 ] || { echo "IOS_BLUR_SCROLL_FAIL (${FAILS[*]})"; exit 1; }
echo "IOS_BLUR_SCROLL_PASS (scale=$SCALE)"
