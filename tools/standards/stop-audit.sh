#!/usr/bin/env bash
# Optional Claude Code Stop hook: run the repo-hygiene standards suite before
# a session hands off a branch. Not installed by default — wire it into
# .claude/settings.json yourself if you want it:
#
#   { "hooks": { "Stop": [{ "hooks": [{ "type": "command",
#        "command": "bash tools/standards/stop-audit.sh" }] }] } }
#
# Runs only on a branch that is ahead of main with a clean tree -- a session
# that hasn't touched any code has nothing to audit, so it exits 0 silently.
# Caches the pass/fail result by HEAD sha so a repeat Stop event on the same
# commit doesn't re-run the suite.
set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"

input="$(cat)"
field() { printf '%s' "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1', ''))" 2>/dev/null; }
stop_active="$(field stop_hook_active)"
cwd="$(field cwd)"
cd "${cwd:-$PWD}" 2>/dev/null || exit 0

branch="$(git branch --show-current 2>/dev/null)"
[ -n "$branch" ] && [ "$branch" != "main" ] || exit 0
[ "$(git rev-list --count main..HEAD 2>/dev/null || echo 0)" -gt 0 ] || exit 0
[ -z "$(git status --porcelain)" ] || exit 0

sha="$(git rev-parse HEAD)"
cache="$(git rev-parse --path-format=absolute --git-path rni-standards-audit)"
mkdir -p "$cache"
if [ -f "$cache/$sha.pass" ]; then exit 0; fi
if [ -f "$cache/$sha.fail" ]; then
  [ "$stop_active" = "True" ] && exit 0
  cat "$cache/$sha.fail" >&2
  exit 2
fi

# Anything RNI_NDA_TERMS_FILE or similar private input points at is this
# machine's own business -- a missing file is handled inside the suite
# itself (see no-nda-terms.test.mjs), never as a reason to fail here.
out="$(node --test tools/standards/*.test.mjs 2>&1)"
code=$?
if [ "$code" -eq 0 ]; then
  printf '%s\n' "$out" > "$cache/$sha.pass"
  exit 0
fi

msg="tools/standards failed on branch $branch ($sha). Fix before handing off:
$(printf '%s\n' "$out" | grep -E 'not ok|AssertionError|✖' | head -20)"
printf '%s\n' "$msg" > "$cache/$sha.fail"
printf '%s\n' "$msg" >&2
exit 2
