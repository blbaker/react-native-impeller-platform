// Standard: "New files stay at or under 300 lines" (docs/engineering-standards.md,
// Minimal surgical edits). Scoped to NEW files on the branch — a pre-existing
// large file that wasn't touched is not this branch's debt to fix.
//
// Scoped further to source/script files, not long-form docs. An append-only
// engineering log is routinely far past 300
// lines by design, and a comprehensive audit or design doc is the same
// shape: the 300-line rule exists to keep CODE reviewable, not to truncate
// prose. Markdown/JSON/YAML are exempt; code and shell/scripts are not.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { addedFiles, baseRef, isOwnedPath, REPO_ROOT } from './lib.mjs';
import { makeBaseRepo, commitFiles } from './test-helpers.mjs';

const MAX_LINES = 300;
const CODE_EXTENSIONS = new Set([
  '.js', '.jsx', '.mjs', '.cjs', '.ts', '.tsx',
  '.c', '.h', '.cc', '.cpp', '.hpp', '.cxx',
  '.sh', '.py',
]);

function countLines(absPath) {
  const text = readFileSync(absPath, 'utf8');
  if (text.length === 0) return 0;
  return text.split('\n').length - (text.endsWith('\n') ? 1 : 0);
}

function checkRepo(cwd) {
  const base = baseRef(cwd);
  const violations = [];
  for (const rel of addedFiles(cwd, base)) {
    if (isOwnedPath(rel)) continue;
    if (!CODE_EXTENSIONS.has(path.extname(rel))) continue;
    const abs = path.join(cwd, rel);
    let lines;
    try {
      lines = countLines(abs);
    } catch {
      continue; // binary or already-deleted in a later commit; not this check's job
    }
    if (lines > MAX_LINES) violations.push({ rel, lines });
  }
  return violations;
}

test('real: new files on this branch stay at or under 300 lines', () => {
  const violations = checkRepo(REPO_ROOT);
  if (violations.length > 0) {
    const detail = violations.map((v) => `  ${v.rel}: ${v.lines} lines`).join('\n');
    assert.fail(`new file(s) exceed ${MAX_LINES} lines:\n${detail}`);
  }
});

test('positive control: a 301-line new file is caught, trimming to 300 clears it', () => {
  const dir = makeBaseRepo();
  const bigFile = Array.from({ length: 301 }, (_, i) => `line ${i}`).join('\n') + '\n';
  commitFiles(dir, { 'src/new-thing.js': bigFile }, 'feat: add oversized new file');

  const caught = checkRepo(dir);
  assert.equal(caught.length, 1, 'expected the oversized new file to be flagged');
  assert.equal(caught[0].rel, 'src/new-thing.js');
  assert.equal(caught[0].lines, 301);

  const trimmed = Array.from({ length: 300 }, (_, i) => `line ${i}`).join('\n') + '\n';
  commitFiles(dir, { 'src/new-thing.js': trimmed }, 'fix: trim new file to 300 lines');
  assert.deepEqual(checkRepo(dir), [], 'a 300-line file must pass');
});

test('positive control: a parity-owned path is never flagged even if oversized', () => {
  const dir = makeBaseRepo();
  const bigFile = Array.from({ length: 500 }, (_, i) => `console.log(${i})`).join('\n') + '\n';
  commitFiles(
    dir,
    { 'docs/eng/flutter-parity/notes.js': bigFile },
    'parity(FP-99): huge notes file',
  );
  assert.deepEqual(checkRepo(dir), [], 'parity-owned paths must be excluded from this check');
});

test('positive control: a long markdown doc is exempt (docs are not code)', () => {
  const dir = makeBaseRepo();
  const bigDoc = Array.from({ length: 500 }, (_, i) => `line ${i}`).join('\n') + '\n';
  commitFiles(dir, { 'docs/REPORT.md': bigDoc }, 'docs: add a long audit report');
  assert.deepEqual(checkRepo(dir), [], 'markdown docs are exempt from the code file-size cap');
});
