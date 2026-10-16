#!/usr/bin/env bash
# Create the cached stock React Native app that every consumer gate copies from.
#
# WHY THIS EXISTS AS A SCRIPT
# ---------------------------
# Four gates (P1 pack-and-consume, P2 mount, P3 conformance, P4 module seam)
# install the packed tarballs into a PRISTINE app outside the repo — that is the
# whole point of them, since a defect in what we ship is invisible from inside
# the source tree. Creating that app takes minutes, so it is cached at
# ~/.cache/rni/base and copied per-run.
#
# ⛔ IT WAS DOCUMENTED AS A COMMAND TO RUN BY HAND, AND THAT IS
# WHY CI COULD NOT RUN THE GATES. Every developer box had the directory from
# some earlier session, so the gates' precondition was satisfied by HISTORY
# rather than by anything in the repo — the same shape as the RN-pin ordering
# bug the first CI run found. A prerequisite that only a human can satisfy is a
# gate that only runs where someone already ran it.
#
# The RN version is read from the same pin the engine compiles against
# (engine/rn/package.json), not hardcoded here. A base app on a different RN
# than the engine's ReactCommon is a bytecode/ABI mismatch that surfaces far
# from its cause.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RN_VERSION="$(node -p "require('./engine/rn/package.json').dependencies['react-native']")"
STAMP="$BASE_APP/.rni-stamp"

if [ -d "$BASE_APP/node_modules/react-native" ] && [ -f "$STAMP" ] \
   && [ "$(cat "$STAMP")" = "$RN_VERSION" ]; then
  echo "base-app: already present at $BASE_APP (RN $RN_VERSION)"
  exit 0
fi

# A base app at the WRONG version is worse than none: the gates would copy it
# and fail somewhere deep in the bundle. Rebuild rather than reuse.
if [ -d "$BASE_APP" ]; then
  echo "base-app: stale or unversioned base at $BASE_APP — rebuilding for RN $RN_VERSION"
  rm -rf "$BASE_APP"
fi

echo "base-app: creating stock RN $RN_VERSION app (this takes a few minutes)"
mkdir -p "$(dirname "$BASE_APP")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --skip-git-init: this is a fixture, not a project.
# --install-pods false: no CocoaPods on Linux, and iOS is not a target here.
# --pm npm: the lockfile the gates expect.
(cd "$TMP" && npx --yes @react-native-community/cli@latest init RniConsumer \
    --version "$RN_VERSION" --skip-git-init --install-pods false --pm npm \
    --directory RniConsumer) > "$TMP/init.log" 2>&1 || {
  echo "base-app: FAIL: RN app creation failed" >&2
  tail -30 "$TMP/init.log" >&2
  exit 1
}

[ -d "$TMP/RniConsumer/node_modules/react-native" ] || {
  echo "base-app: FAIL: init reported success but produced no node_modules/react-native" >&2
  tail -30 "$TMP/init.log" >&2
  exit 1
}

# Verify the app is the version we asked for. `init --version` has been known to
# resolve differently than requested, and every gate downstream would then be
# testing against an RN the engine was not built for.
GOT="$(node -p "require('$TMP/RniConsumer/node_modules/react-native/package.json').version")"
[ "$GOT" = "$RN_VERSION" ] || {
  echo "base-app: FAIL: asked for RN $RN_VERSION, got $GOT" >&2
  exit 1
}

mv "$TMP/RniConsumer" "$BASE_APP"
echo "$RN_VERSION" > "$STAMP"
echo "BASE_APP_OK $BASE_APP (RN $GOT)"
