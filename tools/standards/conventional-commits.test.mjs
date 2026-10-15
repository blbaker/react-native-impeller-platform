// Standard: "Conventional commit subjects" (docs/engineering-standards.md,
// Reviewable). Checks every commit subject on this branch (base..HEAD)
// against the Conventional Commits grammar: type(scope)?: description.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { commitSubjects, baseRef, REPO_ROOT } from './lib.mjs';
import { makeBaseRepo, commitFiles } from './test-helpers.mjs';

const TYPES = [
  'feat', 'fix', 'docs', 'style', 'refactor', 'perf', 'test',
  'build', 'ci', 'chore', 'revert',
];
const PATTERN = new RegExp(`^(${TYPES.join('|')})(\\([^)]+\\))?!?: .+`);

// Merge commits and the parity bot's own `parity(...)`/`fix-up` commits
// don't follow this grammar and aren't this check's concern — this suite
// only runs on a feature branch's own commits, and a merge of origin/main
// is not a violation of anything.
function isExempt(subject) {
  return subject.startsWith('Merge ') || subject.startsWith('Revert "');
}

function checkSubjects(subjects) {
  return subjects.filter((s) => !isExempt(s) && !PATTERN.test(s));
}

test('real: every commit subject on this branch is a conventional commit', () => {
  const subjects = commitSubjects(REPO_ROOT, baseRef(REPO_ROOT));
  const bad = checkSubjects(subjects);
  if (bad.length > 0) {
    assert.fail(
      `non-conventional commit subject(s):\n${bad.map((s) => `  "${s}"`).join('\n')}\n` +
        `expected one of: ${TYPES.join(', ')} with an optional (scope) and "!" for breaking`,
    );
  }
});

test('positive control: a plain-English subject is caught, a conventional one passes', () => {
  const dir = makeBaseRepo();
  commitFiles(dir, { 'a.txt': 'x' }, 'fixed the thing that was broken');
  const bad = checkSubjects(commitSubjects(dir, 'main'));
  assert.deepEqual(bad, ['fixed the thing that was broken']);

  commitFiles(dir, { 'a.txt': 'y' }, 'fix: correct the broken thing');
  const nowBad = checkSubjects(commitSubjects(dir, 'main'));
  assert.deepEqual(nowBad, ['fixed the thing that was broken']); // the earlier bad one is still there
});

test('positive control: a scoped and a breaking-change subject both pass', () => {
  const dir = makeBaseRepo();
  commitFiles(dir, { 'a.txt': 'x' }, 'feat(core): add resize handling');
  commitFiles(dir, { 'b.txt': 'y' }, 'feat!: drop the v1 resolver API');
  assert.deepEqual(checkSubjects(commitSubjects(dir, 'main')), []);
});
