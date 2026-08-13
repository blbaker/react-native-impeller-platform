#!/usr/bin/env bash
# Apply the tracked MSVC portability patches to the vendored RN tree.
#
# WHY A SCRIPT AND NOT HAND EDITS
#   These files live in engine/rn/node_modules, which is .gitignore'd and
#   recreated by `npm install`. A hand edit is invisible to git, survives
#   nothing, and silently un-fixes the Windows build the next time anyone
#   reinstalls. Every change here is idempotent and re-appliable.
#
# ⛔ EVERY PATCH ABORTS IF ITS ANCHOR IS ABSENT.
#   A find/replace against source that has been refactored leaves the tree
#   UNMUTATED, the build stays green for the wrong reason, and the run reports
#   success. Measured on this project in P3: a mutation script had silently
#   become a no-op and reported its mutant as uncaught.
#
# Run automatically by tools/win-sync.sh; safe to run on Linux (it is, in fact,
# where it runs — the tree is patched before being staged to Windows).
set -euo pipefail
cd "$(dirname "$0")/.."
RC="engine/rn/node_modules/react-native/ReactCommon"
[ -d "$RC" ] || { echo "apply-win-patches: FAIL — $RC missing (npm install first)" >&2; exit 1; }

python3 - "$RC" <<'PY'
import sys, pathlib, re

rc = pathlib.Path(sys.argv[1])
changed = 0
already = 0

# ---------------------------------------------------------------------------
# PATCH 1 — backticks inside `#pragma mark`.
#
# `#pragma mark ``foo`` ` is an Xcode section marker. MSVC does not know the
# pragma, warns C4068 — and then the LEXER still tokenises the payload, giving
# `error C2018: unknown character '0x60'`.
#
# ⛔ /wd4068 DOES NOT FIX THIS. It silences the WARNING; the C2018s come from a
# different stage and survive it. (Measured on skia-platform: `cl /wd4068`
# still exited 2 with the same four C2018s.)
#
# ⛔ AND THE REPLACEMENT MUST BE INERT TO THE LEXER, NOT MERELY TO A READER.
# Substituting single quotes moved the error rather than fixing it: MSVC then
# lexed 'Node' as a character literal (C2015: too many characters in constant).
# Quote characters of every kind are significant — DELETE them.
#
# The match covers BOTH the original backticks and a tree left in the
# single-quote intermediate state, so a half-patched tree converges.
# ---------------------------------------------------------------------------
for path in rc.rglob("*"):
    if path.suffix not in (".h", ".cpp") or not path.is_file():
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    if "#pragma mark" not in text:
        continue
    out = []
    hit = False
    for line in text.split("\n"):
        if line.lstrip().startswith("#pragma mark") and ("`" in line or "'" in line):
            out.append(line.replace("`", "").replace("'", ""))
            hit = True
        else:
            out.append(line)
    if hit:
        path.write_text("\n".join(out), encoding="utf-8")
        print(f"apply-win-patches: pragma-mark backticks -> {path.relative_to(rc)}")
        changed += 1

if changed == 0:
    # Not a failure on a re-run: the patch is idempotent and legitimately finds
    # nothing the second time. Report it plainly rather than claiming work.
    print("apply-win-patches: pragma-mark — nothing to do (already applied)")
else:
    print(f"apply-win-patches: pragma-mark — patched {changed} file(s)")
PY

# ---------------------------------------------------------------------------
# PATCH 2 — `TextLayoutManager` / feature-flag RN_EXPORT is a GCC attribute.
#
# Handled by a -D, NOT by editing 11 files: every one of the 11 definitions is
# wrapped in `#ifndef RN_EXPORT`, so a command-line define wins everywhere.
# COUNTED, not assumed — and upstream already ships exactly this fix in
# cxxreact/JSBigString.h (`#ifdef _MSC_VER` -> empty), which is what makes the
# override safe rather than a guess.
#
# An EMPTY macro is the CORRECT value, not a cop-out: visibility("default") is
# ELF symbol visibility, meaningless for a static lib on Windows, and
# __declspec(dllexport) would be actively wrong here.
#
# The define lives in engine/CMakeLists.txt (search RN_EXPORT), not here,
# because it is a compile flag rather than a source change.
# ---------------------------------------------------------------------------
GUARDED=$(grep -rl "define RN_EXPORT" --include=*.h "$RC" | wc -l)
UNGUARDED=0
for f in $(grep -rl "define RN_EXPORT" --include=*.h "$RC"); do
  if [ "$(grep -B1 "define RN_EXPORT" "$f" | grep -c ifndef)" = "0" ]; then
    # JSBigString.h nests its #ifdef _MSC_VER INSIDE an #ifndef, so grep -B1
    # sees the inner line. Re-check with a wider window before failing.
    if [ "$(grep -B3 "define RN_EXPORT" "$f" | grep -c ifndef)" = "0" ]; then
      echo "apply-win-patches: FAIL — unguarded RN_EXPORT in $f; the -DRN_EXPORT= override cannot win" >&2
      UNGUARDED=1
    fi
  fi
done
[ "$UNGUARDED" = "0" ] || exit 1
echo "apply-win-patches: RN_EXPORT — ${GUARDED} definitions, all #ifndef-guarded (override is safe)"

echo "APPLY_WIN_PATCHES_OK"
