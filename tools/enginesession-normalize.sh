#!/usr/bin/env bash
# Normalizes a tools/ci-all.sh log so two runs on the SAME tree compare
# equal, by collapsing fields that vary from run to run for reasons that
# have nothing to do with engine behavior. Used by
# tools/ci-enginesession-characterize.sh, and tested directly (without
# running ci-all.sh at all) by
# tools/mutation-verify-enginesession-characterize.sh.
#
#   stdin  = a tools/ci-all.sh log
#   stdout = the same log with run-varying fields replaced by placeholders
#
# Each rule is evidence-based (found by diffing two real ci-all.sh runs on
# an unmodified tree), not a guess -- see the comment next to it for why.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

awk '
  # gate 9 (darwin staging fetchers) prints a DIFFERENT NUMBER OF LINES
  # depending on whether engine/third_party/*-darwin* was already on disk
  # (cache hit: one "already present, up to date" line per tool) or had
  # to be fetched (cache miss: "ABI parity OK" + an _OK line per tool).
  # That is this machine/runners cache state, not engine behavior.
  # Collapse the whole block to its own header line so the two logs
  # realign regardless of which form either run hit.
  /^### gate 9: darwin staging fetchers$/ { print; skip=1; next }
  /^### gate 10: release metadata$/ { skip=0 }
  skip { next }
  { print }
' | sed -E -f "${SELF_DIR}/enginesession-normalize.sed"
