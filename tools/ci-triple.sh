#!/usr/bin/env bash
# The HOST triple, in node's own vocabulary — the single definition every gate
# uses instead of hardcoding "linux x64".
#
# ⛔ WHY THIS FILE EXISTS
# Four consumer gates (P1/P2/P3/P4) each contained `engine-build.sh linux x64`
# and `packages-engine/engine-linux-x64` written out by hand. On a Mac every one
# of them tried to build the LINUX engine, which fails at the first
# platform-specific line — so the gates could not run on the second host at all,
# for a reason that had nothing to do with the port.
#
# This is the same shape as the P5-E finding (hand-copied fixture assertions):
# the value was duplicated per gate, so fixing one did not fix the others.
# N gates x M hosts of copied triples is unmaintainable at N=4, M=3.
#
# ⛔ THE TRIPLE MUST MATCH node's process.platform-process.arch EXACTLY.
# resolve.js computes the engine package name from those values at runtime, so
# a friendly name like "macos-arm64" produces a package that builds fine,
# publishes fine, and can never be found. Derived from node itself rather than
# from uname, so there is no translation table to drift.
#
# Usage:
#   . "$CI_TOOLS/ci-triple.sh"
#   bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH"
#   ... "packages-engine/engine-${RNI_TRIPLE}" ...

# ⛔ A MISSING node MUST STOP THE GATE, NOT PRODUCE AN EMPTY TRIPLE.
# `node -p ...` on a host without node in PATH prints an error to stderr and
# yields an EMPTY string, so RNI_TRIPLE silently became "-" and
# RNI_ENGINE_PKG "packages-engine/engine--". Every downstream check then
# operated on nonsense paths: the registry gate ran for two minutes and exited
# with NO output at all, which reads as a hung or crashed script rather than a
# missing interpreter.
#
# Hit for real over SSH, where a non-interactive shell does not source the
# rc file that puts nvm's node on PATH. Fail loudly, and say what to do.
RNI_PLATFORM="$(node -p 'process.platform' 2>/dev/null)"
RNI_ARCH="$(node -p 'process.arch' 2>/dev/null)"
if [ -z "$RNI_PLATFORM" ] || [ -z "$RNI_ARCH" ]; then
  echo "ci-triple: FAIL — cannot determine the host triple: node is not on PATH." >&2
  echo "  Every gate derives its engine package name from node's own" >&2
  echo "  process.platform/process.arch, so there is no safe fallback." >&2
  echo "  Over SSH this usually means a non-interactive shell did not load nvm:" >&2
  echo "    . \"\$HOME/.nvm/nvm.sh\"   (or run the gate from a login shell)" >&2
  return 1 2>/dev/null || exit 1
fi
RNI_TRIPLE="${RNI_PLATFORM}-${RNI_ARCH}"
RNI_ENGINE_PKG="packages-engine/engine-${RNI_TRIPLE}"
export RNI_PLATFORM RNI_ARCH RNI_TRIPLE RNI_ENGINE_PKG
