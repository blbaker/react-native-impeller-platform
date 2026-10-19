#!/usr/bin/env bash
# Run a command in a copy of this worktree on a Mac, over ssh, from linux.
# The iOS gates and builds need Xcode and the iOS Simulator; this lets them be
# started from a linux box that can reach a Mac.
#
#   RNI_MAC_HOST=<ssh host> bash tools/mac-run.sh <cmd> [args...]
#
# Env:
#   RNI_MAC_HOST  ssh host of the Mac (required; key auth, no prompts)
#   RNI_MAC_TREE  the copy's directory under the Mac's $HOME (default rni-mac-run)
#   RNI_MAC_ENV   space-separated names of variables to forward (only set ones go)
#
# The copy gets every tracked file plus untracked files that are not ignored,
# then both sides' sha256 lists are compared. Ignored paths on the Mac (staged
# SDKs, Hermes, node_modules, build dirs) are never deleted by the sync, so a
# Mac-built input survives later runs. The command runs with Homebrew first on
# PATH: macOS's /bin/bash is 3.2 and the gates need bash 4+.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
HOST="${RNI_MAC_HOST:?RNI_MAC_HOST=<ssh host of a Mac> is required}"
TREE="${RNI_MAC_TREE:-rni-mac-run}"
say() { echo "[mac-run] $*"; }
die() { say "FAIL: $*" >&2; exit 1; }
mac() { ssh -o BatchMode=yes -o ConnectTimeout=20 "$HOST" "$@"; }
[ $# -ge 1 ] || { echo "usage: RNI_MAC_HOST=<host> $0 <cmd> [args...]" >&2; exit 64; }
case "$TREE" in /* | *..* | "") die "RNI_MAC_TREE must be a relative path under the Mac's \$HOME" ;; esac

mac "mkdir -p ~/$TREE" || die "cannot reach $HOST"
rsync -a --delete --exclude /.git \
  --filter='P /engine/third_party/***' --filter='P /engine/rn/node_modules/***' \
  --filter='P /engine/build*/***' --filter='P /packages-engine/*/bin/***' \
  --filter=':- .gitignore' "$ROOT/" "$HOST:$TREE/" || die "rsync failed"

files=$(git ls-files --cached --others --exclude-standard | while read -r f; do
  [ -f "$f" ] && [ ! -L "$f" ] && echo "$f"
done)
want=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 shasum -a 256 | sort -k2 | shasum -a 256 | cut -c1-16)
got=$(printf '%s\n' "$files" | tr '\n' '\0' | mac "cd ~/$TREE && xargs -0 shasum -a 256" | sort -k2 | shasum -a 256 | cut -c1-16)
[ "$want" = "$got" ] || die "tree hash on the Mac ($got) != local ($want) after rsync"
head="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . 2> /dev/null || echo -dirty)"
say "sync ok: $(printf '%s\n' "$files" | grep -c .) files, tree $want, head $head -> $HOST:~/$TREE"

envs=""
for v in ${RNI_MAC_ENV:-}; do
  [ -n "${!v:-}" ] && envs="$envs $v=$(printf '%q' "${!v}")"
done
cmd=""
for a in "$@"; do cmd="$cmd $(printf '%q' "$a")"; done
mac "cd ~/$TREE && export PATH=/opt/homebrew/bin:\$PATH && env$envs$cmd"
