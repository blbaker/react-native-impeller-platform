#!/usr/bin/env bash
# Mutation verification for tools/ci-workflows.sh.
#
# The gate passed on its first run against the real workflows, which is the
# least trustworthy possible result: a script that prints PASS unconditionally
# does that too. Each mutation below breaks the pipeline in a way a reviewer
# would plausibly wave through, and the gate must redden — with the RIGHT tag,
# because "it exited non-zero" is not evidence about the rule under test.
#
# ⛔ MUTANTS RUN AGAINST A COPY, INSIDE THE REPO.
# The gate does `cd "$(dirname "$0")/.."` to reach the repo root, so a copy in
# $(mktemp -d) resolves that to `/` and dies before reaching any rule — a
# non-zero exit a naive harness scores as "caught". The workflow copies live in
# .mut-wf-$$/ at the repo root and the gate is pointed at them by argument, so
# every mutant runs from exactly where the real script runs.
#
# ⛔ AND EACH MUTANT MUST PROVE IT REACHED THE RULE.
# WORKFLOW_GATE_START must appear in the output, and the expected tag must be
# present. A mutant that dies early, or reddens for an unrelated reason, is
# reported INCONCLUSIVE rather than credited.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

SRC=".github/workflows"
WORK=".mut-wf-$$"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0; N=0

# Run the gate against a mutated copy and score it.
#   $1 label  $2 expected tag  $3 python mutator (operates on $WORK)
mutate() {
  local label="$1" tag="$2" mutator="$3"
  N=$((N+1))
  rm -rf "$WORK"; cp -r "$SRC" "$WORK"

  # NON-VACUITY: a mutation that changes nothing tests nothing. Same family as
  # `cmp "$f" "$f"`. Before running the gate, prove the bytes actually moved.
  local before after
  before="$(cat "$WORK"/*.y*ml | md5sum | cut -d' ' -f1)"
  python3 -c "$mutator" "$WORK" || {
    echo "  M${N} ${label}: INCONCLUSIVE (mutator itself failed)"; FAIL=$((FAIL+1)); return; }
  after="$(cat "$WORK"/*.y*ml | md5sum | cut -d' ' -f1)"
  if [ "$before" = "$after" ]; then
    echo "  M${N} ${label}: INCONCLUSIVE (mutation changed nothing — it cannot fail)"
    FAIL=$((FAIL+1)); return
  fi

  local out rc
  out="$(bash tools/ci-workflows.sh "$WORK" 2>&1)"; rc=$?

  if ! grep -q "WORKFLOW_GATE_START" <<<"$out"; then
    echo "  M${N} ${label}: INCONCLUSIVE (gate never started)"
    FAIL=$((FAIL+1)); return
  fi
  if [ "$rc" -eq 0 ]; then
    echo "  M${N} ${label}: NOT CAUGHT (gate still passed)"
    FAIL=$((FAIL+1)); return
  fi
  if ! grep -q "WORKFLOW_FAIL\[${tag}\]" <<<"$out"; then
    echo "  M${N} ${label}: WRONG REASON (expected ${tag}, got: $(grep -o 'WORKFLOW_FAIL\[[A-Z0-9]*\]' <<<"$out" | sort -u | tr '\n' ' '))"
    FAIL=$((FAIL+1)); return
  fi
  echo "  M${N} ${label}: caught (${tag})"
  PASS=$((PASS+1))
}

echo "MUTATION_VERIFY_WORKFLOWS_START"

# ── The control. An unmutated copy must PASS, or every red below is meaningless.
rm -rf "$WORK"; cp -r "$SRC" "$WORK"
if out="$(bash tools/ci-workflows.sh "$WORK" 2>&1)" && grep -q "WORKFLOW_GATE_PASS" <<<"$out"; then
  echo "  M0 control (unmutated copy): passes"
else
  echo "  M0 control: FAILED — the copy does not pass, so no mutation result below"
  echo "     can be attributed to the mutation. Output:"; echo "$out"
  exit 1
fi

# ── W3: the release workflow becomes reachable by pushing a branch.
# One added line. This is the whole ballgame: it turns every merge to main into
# a publish attempt.
mutate "publish reachable from a branch push" W3 '
import sys, re, pathlib
p = pathlib.Path(sys.argv[1], "release.yml")
s = p.read_text().replace("    tags: [\x27v*\x27]", "    tags: [\x27v*\x27]\n    branches: [main]")
p.write_text(s)
'

# ── W5: the publish job stops waiting for the gates.
# Deleting one line means a tag publishes without a single test having run.
mutate "publish no longer needs the gates" W5 '
import sys, pathlib
p = pathlib.Path(sys.argv[1], "release.yml")
p.write_text(p.read_text().replace("    needs: gates\n", ""))
'

# ── W8: the dry-run flag is dropped from the always-on publish step.
# The most innocuous-looking edit in the set — it reads like a cleanup, and it
# arms the pipeline permanently, ignoring the repository variable entirely.
mutate "--dry-run removed from the unguarded publish" W8 '
import sys, pathlib
p = pathlib.Path(sys.argv[1], "release.yml")
s = p.read_text().replace("npm publish ./package --dry-run", "npm publish ./package")
s = s.replace("npm publish \"$p\" --dry-run", "npm publish \"$p\"")
p.write_text(s)
'

# ── W4: the PR workflow gains write permission.
# A pull request from a fork then runs with a token that can push.
mutate "pull_request workflow granted write permission" W4 '
import sys, pathlib
p = pathlib.Path(sys.argv[1], "ci.yml")
p.write_text(p.read_text().replace("  contents: read", "  contents: write"))
'

# ── W4 (absent form): the permissions block is deleted outright.
# Token scope then falls back to a repository-wide setting no file can see —
# "probably read-only" is not a check.
mutate "permissions block deleted from the PR workflow" W4 '
import sys, pathlib
p = pathlib.Path(sys.argv[1], "ci.yml")
p.write_text(p.read_text().replace("permissions:\n  contents: read\n", ""))
'

# ── W2: pull_request_target.
# Hands repository secrets to unreviewed fork code. Looks like a synonym for
# pull_request and is not.
mutate "pull_request_target instead of pull_request" W2 '
import sys, pathlib
p = pathlib.Path(sys.argv[1], "ci.yml")
p.write_text(p.read_text().replace("  pull_request:\n", "  pull_request_target:\n"))
'

# ── W9: the gates stop running on pull requests.
# The check job survives, still green, running nothing that matters.
mutate "PR job no longer runs ci-all.sh" W9 '
import sys, pathlib
p = pathlib.Path(sys.argv[1], "ci.yml")
p.write_text(p.read_text().replace("bash tools/ci-all.sh", "echo skipping"))
'

# ── W6: a step references a script that does not exist.
# Fails in CI, minutes in, on a runner — free to catch here.
mutate "step runs a nonexistent gate script" W6 '
import sys, pathlib
p = pathlib.Path(sys.argv[1], "ci.yml")
p.write_text(p.read_text().replace("bash tools/ci-all.sh", "bash tools/ci-everything.sh"))
'

# ── W7: an action is pinned to a floating branch.
# Whatever that branch holds tomorrow runs with this repo|s token.
mutate "action pinned to a floating branch ref" W7 '
import sys, pathlib
p = pathlib.Path(sys.argv[1], "ci.yml")
p.write_text(p.read_text().replace("actions/checkout@v4", "actions/checkout@main"))
'

# ── W10: the PR workflow gains a registry credential.
# A publish token readable by any pull-request run.
mutate "NPM token referenced from the PR workflow" W10 '
import sys, pathlib
p = pathlib.Path(sys.argv[1], "ci.yml")
p.write_text(p.read_text().replace(
  "      - name: Run all gates",
  "      - name: Leak\n        env:\n          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}\n        run: echo hi\n      - name: Run all gates"))
'

# ── W11: workflow_dispatch added to the release workflow.
# A legitimate convenience that also lets the publish job be run from an
# arbitrary branch, with no tag anywhere in sight.
mutate "workflow_dispatch added to the release workflow" W11 '
import sys, pathlib
p = pathlib.Path(sys.argv[1], "release.yml")
s = p.read_text().replace("on:\n  push:", "on:\n  workflow_dispatch:\n  push:")
# Also strip the runtime ref assertion, otherwise the rule is satisfied.
s = s.replace("refs/tags/v", "REDACTED_REF")
p.write_text(s)
'

# ── The SYNTAX layer, which the policy rules structurally cannot reach.
# A typo'd expression context is valid YAML and satisfies every policy rule
# above — `varz.RNI_PUBLISH_ENABLED` still CONTAINS the guard name, so W8 is
# happy — and it fails on the runner. This mutation is the evidence that the
# actionlint hook is load-bearing rather than decorative: the policy gate must
# PASS it and actionlint must catch it. If actionlint is not installed the
# mutation is reported INCONCLUSIVE, never as a pass.
N=$((N+1))
rm -rf "$WORK"; cp -r "$SRC" "$WORK"
python3 - "$WORK" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1], "release.yml")
p.write_text(p.read_text().replace("vars.RNI_PUBLISH_ENABLED ==",
                                   "varz.RNI_PUBLISH_ENABLED =="))
PY
out="$(bash tools/ci-workflows.sh "$WORK" 2>&1)"; rc=$?
if grep -q "SKIPPED actionlint" <<<"$out"; then
  echo "  M${N} typo'd expression context: INCONCLUSIVE (actionlint not installed)"
  FAIL=$((FAIL+1))
elif [ "$rc" -ne 0 ] && grep -q "WORKFLOW_GATE_FAIL (actionlint)" <<<"$out"; then
  # And confirm the policy layer did NOT catch it — that is the point.
  if grep -q "WORKFLOW_POLICY_PASS" <<<"$out"; then
    echo "  M${N} typo'd expression context: caught (actionlint; policy passed it, as expected)"
    PASS=$((PASS+1))
  else
    echo "  M${N} typo'd expression context: WRONG REASON (policy also reddened)"
    FAIL=$((FAIL+1))
  fi
else
  echo "  M${N} typo'd expression context: NOT CAUGHT (rc=${rc})"
  FAIL=$((FAIL+1))
fi

# ── The skip must be refusable. RNI_REQUIRE_ACTIONLINT=1 with the binary
# unreachable has to FAIL, not skip — "cannot check" and "checked and fine"
# must not share an exit status.
#
# ⛔ DO NOT SIMULATE "MISSING" BY EMPTYING PATH. The first draft used
# PATH=/nonexistent, which killed `dirname` on line 32 and the gate died with
# `dirname: command not found` before printing WORKFLOW_GATE_START — a non-zero
# exit that looks like a catch and proves nothing about the actionlint branch.
# Disable only the lookup, and assert the gate actually STARTED.
N=$((N+1))
rm -rf "$WORK"; cp -r "$SRC" "$WORK"
out="$(RNI_REQUIRE_ACTIONLINT=1 RNI_NO_ACTIONLINT_FALLBACK=1 \
        bash tools/ci-workflows.sh "$WORK" 2>&1)"; rc=$?
if ! grep -q "WORKFLOW_GATE_START" <<<"$out"; then
  echo "  M${N} required-but-missing actionlint: INCONCLUSIVE (gate never started)"
  FAIL=$((FAIL+1))
elif [ "$rc" -ne 0 ] && grep -q "RNI_REQUIRE_ACTIONLINT=1 but actionlint is not installed" <<<"$out"; then
  echo "  M${N} required-but-missing actionlint: caught (skip is a failure)"
  PASS=$((PASS+1))
else
  echo "  M${N} required-but-missing actionlint: NOT CAUGHT (rc=${rc})"
  FAIL=$((FAIL+1))
fi

# ── W12: the lock weakened to a ref check that is always true.
# The most dangerous plausible edit now that the 402 backstop is gone. It reads
# as "tighten the release condition to tags only" and, on a workflow that ONLY
# triggers on tags, evaluates true on every run — publishing unconditionally
# without ever naming the guard variable.
mutate "publish gated on the ref alone instead of the guard" W12 '
import sys, pathlib
p = pathlib.Path(sys.argv[1], "release.yml")
s = p.read_text()
s = s.replace("npm publish ./package --dry-run", "npm publish ./package")
s = s.replace("npm publish \"$p\" --dry-run", "npm publish \"$p\"")
s = s.replace("      - name: Publish (dry run)",
              "      - name: Publish (dry run)\n        if: startsWith(github.ref, \x27refs/tags/v\x27)")
p.write_text(s)
'

# ── W1: the workflow directory is emptied.
# "The gates run on every PR" with nothing implementing it. A gate that treats
# no-workflows as nothing-to-check would pass here, which is the silent-skip
# failure mode this program keeps finding.
N=$((N+1))
rm -rf "$WORK"; mkdir -p "$WORK"
out="$(bash tools/ci-workflows.sh "$WORK" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "no workflow files found" <<<"$out"; then
  echo "  M${N} no workflows at all: caught (W1)"
  PASS=$((PASS+1))
else
  echo "  M${N} no workflows at all: NOT CAUGHT (rc=${rc})"
  FAIL=$((FAIL+1))
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "MUTATION_VERIFY_WORKFLOWS_PASS (${PASS}/${N})"
else
  echo "MUTATION_VERIFY_WORKFLOWS_FAIL (${FAIL} of ${N} not properly caught)" >&2
  exit 1
fi
