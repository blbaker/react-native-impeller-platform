// Standard: "A new tools/ci-*.sh ships a matching tools/mutation-verify-*.sh
// in the same PR" (docs/engineering-standards.md, Tests and proof). Checks
// files newly ADDED on this branch — a gate added in an earlier commit and
// not touched here is not this branch's problem to fix.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { addedFiles, baseRef, REPO_ROOT } from './lib.mjs';
import { makeBaseRepo, commitFiles } from './test-helpers.mjs';

const CI_GATE = /^tools\/ci-(.+)\.sh$/;

function checkRepo(cwd) {
  const base = baseRef(cwd);
  const added = new Set(addedFiles(cwd, base));
  const missing = [];
  for (const rel of added) {
    const m = CI_GATE.exec(rel);
    if (!m) continue;
    const expected = `tools/mutation-verify-${m[1]}.sh`;
    const shipped = added.has(expected) || existsSync(path.join(cwd, expected));
    if (!shipped) missing.push({ gate: rel, expected });
  }
  return missing;
}

test('real: every new tools/ci-*.sh ships a matching mutation-verify script', () => {
  const missing = checkRepo(REPO_ROOT);
  if (missing.length > 0) {
    const detail = missing
      .map((m) => `  ${m.gate} has no ${m.expected}`)
      .join('\n');
    assert.fail(`new CI gate(s) with no mutation-verify script:\n${detail}`);
  }
});

test('positive control: a new gate with no mutation-verify is caught', () => {
  const dir = makeBaseRepo();
  commitFiles(
    dir,
    { 'tools/ci-widget.sh': '#!/usr/bin/env bash\necho WIDGET_PASS\n' },
    'feat: add a widget gate',
  );
  const missing = checkRepo(dir);
  assert.equal(missing.length, 1);
  assert.equal(missing[0].gate, 'tools/ci-widget.sh');
  assert.equal(missing[0].expected, 'tools/mutation-verify-widget.sh');
});

test('positive control: adding the mutation-verify script in the same commit clears it', () => {
  const dir = makeBaseRepo();
  commitFiles(
    dir,
    {
      'tools/ci-widget.sh': '#!/usr/bin/env bash\necho WIDGET_PASS\n',
      'tools/mutation-verify-widget.sh': '#!/usr/bin/env bash\necho WIDGET_MUTATION_PASS\n',
    },
    'feat: add a widget gate with its mutation-verify script',
  );
  assert.deepEqual(checkRepo(dir), []);
});
