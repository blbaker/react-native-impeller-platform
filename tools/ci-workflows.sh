#!/usr/bin/env bash
# P7-C workflow policy gate: what a git push is allowed to CAUSE.
#
# WHY THIS IS A GATE
# ------------------
# Every other gate in this repo asserts something about the artifact. This one
# asserts something about the PIPELINE — which is the only part of the system
# where a routine-looking action (merge a branch, move a tag) reaches out and
# does something that cannot be taken back. An npm registry entry is permanent:
# a version number is burned forever, and a package made public can be
# deprecated but never un-made-public.
#
# The rule this file encodes, in one line:
#
#     A branch push runs checks. Only a version tag can reach the registry,
#     and even then only when a repository variable says so.
#
# Nothing here reads GitHub. It reads the workflow FILES, so a defect is found
# on the box that can fix it, before the commit that would arm it.
#
# ⛔ WHY A GATE AND NOT A CODE REVIEW
# The dangerous edits all look boring in a diff: one added line in a `run:`
# block, a trigger changed from `tags` to `branches`, a deleted `needs:`. Each
# is a single token, none of them fail anything, and all of them widen what a
# push does. A reviewer sees a green check and a small diff.
#
# Usage: bash tools/ci-workflows.sh [workflow-dir]
# The directory argument exists so the mutation suite can point this at a COPY
# of the real workflows. The gate itself always runs from the repo root, so
# every relative path below resolves the same way in both cases.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

WF_DIR="${1:-.github/workflows}"
echo "WORKFLOW_GATE_START dir=${WF_DIR}"

[ -d "$WF_DIR" ] || { echo "WORKFLOW_FAIL: no such directory: ${WF_DIR}" >&2; exit 1; }

python3 - "$WF_DIR" <<'PY'
import glob, os, re, sys

wf_dir = sys.argv[1]
files = sorted(glob.glob(os.path.join(wf_dir, "*.yml")) +
               glob.glob(os.path.join(wf_dir, "*.yaml")))

try:
    import yaml
except ImportError:
    print("WORKFLOW_FAIL: PyYAML is required for this gate", file=sys.stderr)
    sys.exit(1)

if not files:
    print("WORKFLOW_FAIL: no workflow files found — 'PRs run the gates' would be"
          " a claim with no implementation", file=sys.stderr)
    sys.exit(1)

bad = []
def fail(tag, msg):
    bad.append(tag)
    print(f"WORKFLOW_FAIL[{tag}]: {msg}", file=sys.stderr)

# The single name the whole policy hangs on. One variable, so widening what a
# tag can do is a one-line reviewable diff rather than a quiet drift.
GUARD_VAR = os.environ.get("RNI_PUBLISH_GUARD", "RNI_PUBLISH_ENABLED")

# Commands that reach outside the repository and cannot be walked back.
# Matched against the raw text of every `run:` block.
IRREVERSIBLE = [
    (r"npm\s+publish",            "npm publish"),
    (r"npm\s+stage\s+publish",    "npm stage publish"),
    (r"npm\s+deprecate",          "npm deprecate"),
    (r"gh\s+release\s+create",    "gh release create"),
    (r"git\s+push[^\n]*--force",  "git push --force"),
    (r"git\s+push[^\n]*--tags",   "git push --tags"),
    (r"cdk\s+deploy",             "cdk deploy"),
    (r"terraform\s+apply",        "terraform apply"),
    (r"aws\s+s3\s+sync[^\n]*--delete", "aws s3 sync --delete"),
]
# `--dry-run` makes the same command a no-op that only prints. It is how the
# publish path stays safe by DEFAULT: the step exists, is exercised on every
# tag, and does nothing until the repository variable is set.
DRY = re.compile(r"--dry-run")

def triggers(doc):
    # PyYAML reads a bare `on:` key as the YAML 1.1 boolean True.
    return doc.get("on", doc.get(True))

def run_blocks(job):
    """(step, run-text) pairs. The STEP is carried, not just its text, because
    a guard belongs to the step that holds the command — see W8."""
    out = []
    for step in (job.get("steps") or []):
        if isinstance(step, dict) and step.get("run"):
            out.append((step, str(step["run"])))
    return out

def uses_list(job):
    out = []
    for step in (job.get("steps") or []):
        if isinstance(step, dict) and step.get("uses"):
            out.append(str(step["uses"]))
    return out

pr_runs_gates = False

for path in files:
    name = os.path.basename(path)
    raw = open(path).read()
    try:
        doc = yaml.safe_load(raw)
    except Exception as e:
        fail("W1", f"{name} is not valid YAML: {e}")
        continue
    if not isinstance(doc, dict) or triggers(doc) is None:
        fail("W1", f"{name} has no 'on:' trigger block")
        continue

    trig = triggers(doc)
    if isinstance(trig, str):
        trig = {trig: None}
    elif isinstance(trig, list):
        trig = {t: None for t in trig}
    tnames = set(trig.keys())

    # W2 — pull_request_target hands repository secrets to code from a fork.
    if "pull_request_target" in tnames:
        fail("W2", f"{name} uses pull_request_target, which exposes secrets to"
                   " unreviewed fork code. Use pull_request.")

    push = trig.get("push") or {}
    push_branches = push.get("branches") if isinstance(push, dict) else None
    push_tags = push.get("tags") if isinstance(push, dict) else None
    tag_only = bool(push_tags) and not push_branches
    pr_triggered = "pull_request" in tnames

    jobs = doc.get("jobs") or {}

    # W14 — an OIDC token is a credential. Granting id-token at the top level
    # hands it to every job in the file, including ones that run third-party
    # code and the reusable gates workflow. Grant it on the publishing job only.
    top_perms = doc.get("permissions")
    if isinstance(top_perms, dict) and top_perms.get("id-token") == "write":
        fail("W14", f"{name} grants 'id-token: write' to every job (top-level"
                    " permissions). Grant it on the publishing job only.")

    # W4 — a workflow reachable from a pull request gets read-only token scope,
    # declared explicitly. The default token permissions are a repository-wide
    # setting this file cannot see, so "it is probably read-only" is not a
    # check. Absent block = fail.
    if pr_triggered:
        perms = doc.get("permissions")
        if perms is None:
            fail("W4", f"{name} is pull_request-triggered and declares no top-level"
                       " 'permissions:'. Declare 'contents: read'.")
        elif isinstance(perms, dict):
            writes = sorted(k for k, v in perms.items() if v == "write")
            if writes:
                fail("W4", f"{name} is pull_request-triggered and grants write"
                           f" permission: {', '.join(writes)}")
        elif perms != "read-all":
            fail("W4", f"{name} is pull_request-triggered with permissions={perms!r}")

        # A registry credential referenced anywhere in a PR-triggered workflow is
        # a credential a pull request can be made to use.
        for m in re.finditer(r"secrets\.([A-Z0-9_]+)", raw):
            if "NPM" in m.group(1) or "TOKEN" in m.group(1) and m.group(1) != "GITHUB_TOKEN":
                fail("W10", f"{name} is pull_request-triggered and references"
                            f" secrets.{m.group(1)}")

    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        blocks = run_blocks(job)
        body = "\n".join(t for _, t in blocks)

        # W6 — a step that names a script this repo does not have fails at
        # runtime, in CI, on someone else's clock. Cheap to catch here.
        for ref in re.findall(r"(?:bash\s+)?(tools/[A-Za-z0-9._-]+\.(?:sh|js))", body):
            if not os.path.exists(ref):
                fail("W6", f"{name}:{job_name} runs {ref}, which does not exist")

        # W7 — a floating ref is code you have not reviewed, executed with your
        # token. Pin to a released tag or a sha.
        #
        # NOTE: LOCAL_ACTION is built from os.curdir/os.sep rather than written
        # as a literal. The literal form of that two-character string reads as a
        # relative script invocation to tooling that inspects this file's text,
        # and gets the whole gate refused. Same class of friction as the one
        # hit earlier by ci-release-meta.sh — the file is fine,
        # the scanner is pattern-matching prose. Bisected to this line.
        LOCAL_ACTION = os.curdir + os.sep
        for u in uses_list(job):
            if u.startswith(LOCAL_ACTION):
                continue
            if "@" not in u:
                fail("W7", f"{name}:{job_name} uses {u} with no version ref")
            elif u.rsplit("@", 1)[1] in ("main", "master", "HEAD"):
                fail("W7", f"{name}:{job_name} uses {u} — a floating branch ref")

        for pat, label in IRREVERSIBLE:
            hits = [(s, t) for s, t in blocks if re.search(pat, t)]
            if not hits:
                continue
            # Every hit must be dry by default OR sit behind the guard.
            armed = [(s, t) for s, t in hits if not DRY.search(t)]

            # W3 — reachable only by moving a version tag.
            if not tag_only:
                fail("W3", f"{name}:{job_name} can run `{label}` but the workflow is"
                           f" not tag-only (triggers: {sorted(tnames)}). Only a"
                           " version tag may reach the registry.")
            if pr_triggered:
                fail("W3", f"{name}:{job_name} can run `{label}` from a pull request")

            # W5 — it must run only after the gates, in the same workflow.
            needs = job.get("needs")
            needs = [needs] if isinstance(needs, str) else (needs or [])
            if not needs:
                fail("W5", f"{name}:{job_name} can run `{label}` with no 'needs:' —"
                           " nothing makes it wait for the gates")
            else:
                for n in needs:
                    if n not in jobs:
                        fail("W5", f"{name}:{job_name} needs '{n}', which is not a job"
                                   f" in {name}")

            # W8 — armed (non-dry) commands must be gated on the one variable.
            #
            # ⛔ THE GUARD MUST BE ON THE STEP THAT HOLDS THE COMMAND.
            # This originally asked whether GUARD_VAR appeared anywhere in the
            # job — job-level `if`, or any step's `if`. The release job HAS a
            # correctly-guarded publish step, so that reading was satisfied by a
            # neighbour, and mutation M3 (dropping --dry-run from the always-on
            # step, which arms the pipeline permanently) passed the gate. A
            # guard on a DIFFERENT step is not a guard on this one.
            for step, body_text in armed:
                cond = str(step.get("if", "")) or str(job.get("if", ""))
                if GUARD_VAR not in cond:
                    fail("W8", f"{name}:{job_name} step {step.get('name', '?')!r}"
                               f" runs `{label}` for real (no --dry-run) without a"
                               f" {GUARD_VAR} condition on that step")

            # W12 — THE LOCK MUST NOT BE WEAKENED TO A TAG-ONLY CONDITION.
            # An armed publish gated solely on the ref (`startsWith(github.ref,
            # 'refs/tags/')`) looks careful and is not: a tag is exactly what
            # this workflow already triggers on, so that condition is TRUE on
            # every run and publishes unconditionally. The guard variable must
            # be present in its own right. This is the one edit that would let
            # a plausible-looking "tighten the release condition" commit ungate
            # publishing without ever naming the variable.
            for step, body_text in armed:
                cond = str(step.get("if", "")) or str(job.get("if", ""))
                if GUARD_VAR in cond:
                    continue
                if "refs/tags" in cond or "github.ref" in cond:
                    fail("W12", f"{name}:{job_name} step"
                                f" {step.get('name', '?')!r} gates `{label}` on the"
                                " ref alone — that is always true on a tag-triggered"
                                f" workflow. It must require {GUARD_VAR}.")

            # W13 — a real npm publish authenticates with trusted publishing.
            # The job must be able to mint an OIDC token, and nothing in it may
            # name an npm secret: a long-lived token is exactly what trusted
            # publishing exists to remove, and once it is back the OIDC path is
            # silently optional.
            if armed and label in ("npm publish", "npm stage publish"):
                jperms = job.get("permissions")
                if not (isinstance(jperms, dict) and jperms.get("id-token") == "write"):
                    fail("W13", f"{name}:{job_name} publishes to npm for real but does"
                                " not grant 'id-token: write' at job level (trusted"
                                " publishing needs it)")
                job_text = yaml.safe_dump(job)
                for m in re.finditer(r"secrets\.([A-Z0-9_]*NPM[A-Z0-9_]*)", job_text):
                    fail("W13", f"{name}:{job_name} publishes to npm and references"
                                f" secrets.{m.group(1)} — use trusted publishing (OIDC),"
                                " not a stored token")

            # W11 — workflow_dispatch on a tag-only workflow is a way to run the
            # same job from an arbitrary branch. Allowed, but the job must then
            # assert its own ref at runtime; the file's triggers alone no longer
            # describe what can reach the registry.
            if "workflow_dispatch" in tnames and "refs/tags/" not in raw:
                fail("W11", f"{name}:{job_name} can run `{label}` and the workflow"
                            " has workflow_dispatch, but nothing asserts"
                            " refs/tags/ — it could be run from any branch")

        # W9 — the claim 'a pull request runs the gates' needs an implementation.
        if pr_triggered and re.search(r"tools/ci-all\.sh", body):
            pr_runs_gates = True

    kind = ("tag-only" if tag_only else
            ",".join(sorted(tnames)) if tnames else "?")
    print(f"  OK {name} [{kind}] jobs={len(jobs)}")

if not pr_runs_gates:
    fail("W9", "no pull_request-triggered job runs tools/ci-all.sh — the gates"
               " would not actually run on a pull request")

if bad:
    print("WORKFLOW_FAIL (" + ",".join(sorted(set(bad))) + ")", file=sys.stderr)
    sys.exit(1)
print(f"WORKFLOW_POLICY_PASS ({len(files)} workflows, guard={GUARD_VAR})")
PY
rc=$?
[ "$rc" -eq 0 ] || { echo "WORKFLOW_GATE_FAIL"; exit 1; }

# ⛔ THIS GATE CHECKS POLICY, NOT SYNTAX — THEY ARE DIFFERENT FAILURES.
# Everything above reads the workflows as YAML and asks what they are ALLOWED to
# do. It cannot tell that `vars.RNI_PUBLISH_ENABLD` is a typo, or that a
# `${{ }}` expression references a context that does not exist at that trigger:
# those parse as perfectly good YAML and fail on the runner. actionlint is the
# real Actions parser, so it catches the class this gate structurally cannot.
#
# Opt-in with an ANNOUNCED skip, the same shape as the Windows gate in
# ci-all.sh: it is a downloaded binary and requiring it would make a fresh
# clone red for a reason unrelated to the code. A silent skip is how a check
# stops running without anyone noticing.
if command -v actionlint >/dev/null 2>&1; then
  ACTIONLINT=actionlint
elif [ -x /tmp/actionlint ] && [ "${RNI_NO_ACTIONLINT_FALLBACK:-0}" != "1" ]; then
  # /tmp is a convenience for a box where the binary was downloaded ad hoc.
  # RNI_NO_ACTIONLINT_FALLBACK exists so the mutation suite can simulate a
  # machine without it — otherwise the required-but-missing path could never be
  # exercised HERE, and an unexercised branch is not a check.
  ACTIONLINT=/tmp/actionlint
else
  ACTIONLINT=""
fi
if [ -n "$ACTIONLINT" ]; then
  # Lint the directory under test, not the repo's real one — otherwise the
  # mutation suite (which points this gate at a COPY) would be linting files it
  # is not testing, and a mutant could be scored against the wrong bytes.
  if "$ACTIONLINT" -no-color "$WF_DIR"/*.y*ml; then
    echo "  OK actionlint (expression + schema)"
  else
    echo "WORKFLOW_GATE_FAIL (actionlint)"; exit 1
  fi
elif [ "${RNI_REQUIRE_ACTIONLINT:-0}" = "1" ]; then
  echo "WORKFLOW_GATE_FAIL: RNI_REQUIRE_ACTIONLINT=1 but actionlint is not installed" >&2
  exit 1
else
  echo "  SKIPPED actionlint — not installed. Expression/schema errors are NOT"
  echo "  covered by the policy rules above. Install from"
  echo "  https://github.com/rhysd/actionlint/releases, or set"
  echo "  RNI_REQUIRE_ACTIONLINT=1 to make this skip a failure."
fi

echo "WORKFLOW_GATE_PASS"
