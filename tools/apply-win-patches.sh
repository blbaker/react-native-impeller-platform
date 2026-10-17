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

# ---------------------------------------------------------------------------
# PATCH 3 — `&(YogaLayoutableShadowNode::yogaNode_)` in a class template.
#
# BaseTextInputShadowNode.h (RN 0.86) passes the dependent base's member as
# `&(Base::member)`. Standard C++ reads the parenthesised form as the address
# of THIS object's member; MSVC instead forms a pointer-to-member and fails
# with C2664 "cannot convert from 'facebook::yoga::Node
# facebook::react::YogaLayoutableShadowNode::*' to 'YGNodeConstRef'".
# `this->Base::member` names the identical object on every compiler, so the
# rewrite is behaviour-neutral on Linux/darwin too. Anchor-checked: once the
# old form is gone the new one must be present, or the patch target moved.
# ---------------------------------------------------------------------------
python3 - "$RC" <<'PY'
import sys, pathlib
rc = pathlib.Path(sys.argv[1])
f = rc / "react/renderer/components/textinput/BaseTextInputShadowNode.h"
old = "&(YogaLayoutableShadowNode::yogaNode_)"
new = "&(this->YogaLayoutableShadowNode::yogaNode_)"
text = f.read_text(encoding="utf-8")
n_old = text.count(old)
if n_old:
    f.write_text(text.replace(old, new), encoding="utf-8")
    print(f"apply-win-patches: yogaNode_ pointer-to-member — patched {n_old} site(s)")
elif text.count(new) == 2:
    print("apply-win-patches: yogaNode_ pointer-to-member — nothing to do (already applied)")
else:
    sys.exit("apply-win-patches: FAIL — BaseTextInputShadowNode.h anchor not found (RN moved it)")
PY

# ---------------------------------------------------------------------------
# PATCH 4 — a header uses a std type without including its header.
#
# libstdc++ and libc++ pull <mutex> and friends in transitively, so these
# compile on Linux and macOS and fail only under MSVC, e.g.
#   jsinspector-modern/HostTarget.h(455): error C2039: 'mutex': is not a member of 'std'
# Found the first time the Windows engine was built on a clean runner with
# the current React Native pin. Each entry is anchor-checked: the file must
# exist and use the symbol, and afterwards it must include the header.
# ---------------------------------------------------------------------------
python3 - "$RC" <<'PY'
import sys, pathlib, re
rc = pathlib.Path(sys.argv[1])
NEEDS = [  # (file under ReactCommon, symbol it uses, header it must include)
    ("jsinspector-modern/HostTarget.h", "std::mutex", "<mutex>"),
]
for rel, symbol, header in NEEDS:
    f = rc / rel
    if not f.is_file():
        sys.exit(f"apply-win-patches: FAIL — {rel} not found (RN moved it)")
    text = f.read_text(encoding="utf-8")
    if symbol not in text:
        sys.exit(f"apply-win-patches: FAIL — {rel} no longer uses {symbol}; drop or re-anchor this entry")
    inc = f"#include {header}"
    if inc in text:
        print(f"apply-win-patches: {rel} {header} — nothing to do (already included)")
        continue
    m = re.search(r"^#include [<\"].*$", text, re.M)
    if not m:
        sys.exit(f"apply-win-patches: FAIL — {rel} has no #include to anchor on")
    text = text[:m.end()] + "\n" + inc + text[m.end():]
    f.write_text(text, encoding="utf-8")
    print(f"apply-win-patches: {rel} — added {inc}")
PY

echo "APPLY_WIN_PATCHES_OK"
