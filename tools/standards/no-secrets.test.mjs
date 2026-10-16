// Standard: "No secrets in code or config" (docs/engineering-standards.md,
// Code quality). Scans ADDED lines on this branch for common credential
// shapes. This is a lightweight net, not a replacement for a real secret
// scanner, and no substitute for the one-time full-history scan done
// before this repo went public.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addedLinesByFile, baseRef, isOwnedPath, REPO_ROOT } from './lib.mjs';
import { makeBaseRepo, commitFiles } from './test-helpers.mjs';

const PATTERNS = [
  [/AKIA[0-9A-Z]{16}/, 'AWS access key'],
  [/gh[ps]_[A-Za-z0-9]{20,}/, 'GitHub token'],
  [/github_pat_[A-Za-z0-9_]{20,}/, 'GitHub fine-grained PAT'],
  [/sk-[A-Za-z0-9]{20,}/, 'OpenAI-style secret key'],
  [/xox[baprs]-[A-Za-z0-9-]{10,}/, 'Slack token'],
  [/-----BEGIN [A-Z ]*PRIVATE KEY/, 'private key block'],
  [/AIza[0-9A-Za-z_-]{30,}/, 'Google API key'],
  [/npm_[A-Za-z0-9]{36}/, 'npm token'],
];

function scanLine(line) {
  for (const [re, label] of PATTERNS) {
    if (re.test(line)) return label;
  }
  return null;
}

function checkRepo(cwd) {
  const base = baseRef(cwd);
  const hits = [];
  for (const [file, lines] of addedLinesByFile(cwd, base)) {
    if (isOwnedPath(file)) continue;
    // The checker's own source and its positive-control fixtures necessarily
    // contain fake-but-pattern-shaped strings (that's what proves the check
    // can fail) — excluded from its own scan, not exempted from the rule.
    if (file.startsWith('tools/standards/')) continue;
    for (const line of lines) {
      const label = scanLine(line);
      if (label) hits.push({ file, label });
    }
  }
  return hits;
}

test('real: no secret-shaped strings added on this branch', () => {
  const hits = checkRepo(REPO_ROOT);
  if (hits.length > 0) {
    const detail = hits.map((h) => `  ${h.file}: looks like a ${h.label}`).join('\n');
    assert.fail(`possible secret(s) added on this branch:\n${detail}`);
  }
});

test('positive control: a fake AWS key is caught, removing it clears the check', () => {
  const dir = makeBaseRepo();
  commitFiles(
    dir,
    { 'config.js': "const key = 'AKIAABCDEFGHIJKLMNOP';\n" },
    'feat: add config',
  );
  const hits = checkRepo(dir);
  assert.equal(hits.length, 1);
  assert.equal(hits[0].label, 'AWS access key');

  commitFiles(dir, { 'config.js': "const key = process.env.AWS_KEY;\n" }, 'fix: read key from env');
  assert.deepEqual(checkRepo(dir), []);
});

test('positive control: a parity-owned file is never scanned', () => {
  const dir = makeBaseRepo();
  commitFiles(
    dir,
    { 'tools/parity-secret-test.sh': "KEY='AKIAABCDEFGHIJKLMNOP'\n" },
    'parity(FP-99): scratch file with a fake key',
  );
  assert.deepEqual(checkRepo(dir), []);
});
