// Standard: "no NDA terms list kept generic". The ACTUAL list of
// confidential terms never lives in this repo — only the mechanism to check
// against one does. Point RNI_NDA_TERMS_FILE at a local, gitignored text
// file (one term per line) to actually scan for them; absent that file, the
// check passes with nothing to compare against. This mirrors how the
// optional Claude Code Stop hook in tools/standards/stop-audit.sh behaves:
// exit 0 silently when the private half of the setup isn't present.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { addedLinesByFile, baseRef, isOwnedPath, REPO_ROOT } from './lib.mjs';
import { makeBaseRepo, commitFiles } from './test-helpers.mjs';

function loadTerms(termsFilePath) {
  if (!termsFilePath) return [];
  try {
    return readFileSync(termsFilePath, 'utf8')
      .split('\n')
      .map((l) => l.trim())
      .filter((l) => l && !l.startsWith('#'));
  } catch {
    return []; // file doesn't exist here — nothing private to check against
  }
}

function checkRepo(cwd, termsFilePath) {
  const terms = loadTerms(termsFilePath);
  if (terms.length === 0) return { skipped: true, hits: [] };
  const base = baseRef(cwd);
  const hits = [];
  for (const [file, lines] of addedLinesByFile(cwd, base)) {
    if (isOwnedPath(file)) continue;
    for (const line of lines) {
      for (const term of terms) {
        if (line.includes(term)) hits.push({ file, term });
      }
    }
  }
  return { skipped: false, hits };
}

test('real: no terms from RNI_NDA_TERMS_FILE added on this branch', () => {
  const termsFile = process.env.RNI_NDA_TERMS_FILE; // not set in CI or by default — nothing to check
  const { skipped, hits } = checkRepo(REPO_ROOT, termsFile);
  if (skipped) return; // no private terms file on this machine: pass silently
  if (hits.length > 0) {
    const detail = hits.map((h) => `  ${h.file}: contains "${h.term}"`).join('\n');
    assert.fail(`disallowed term(s) added on this branch:\n${detail}`);
  }
});

test('positive control: a seeded generic term is caught against a scratch terms file', () => {
  const tmp = mkdtempSync(path.join(tmpdir(), 'rni-nda-terms-'));
  const termsFile = path.join(tmp, 'terms.local.txt');
  // Deliberately NOT a real confidential term — a generic stand-in so this
  // test (and this file) never has to contain the actual list.
  writeFileSync(termsFile, 'ACME-INTERNAL-PROJECT\n');

  const dir = makeBaseRepo();
  commitFiles(dir, { 'notes.md': 'Ported from the ACME-INTERNAL-PROJECT playbook.\n' }, 'docs: add notes');
  const { skipped, hits } = checkRepo(dir, termsFile);
  assert.equal(skipped, false);
  assert.equal(hits.length, 1);
  assert.equal(hits[0].term, 'ACME-INTERNAL-PROJECT');

  commitFiles(dir, { 'notes.md': 'Ported from the internal playbook.\n' }, 'docs: generalize notes');
  assert.deepEqual(checkRepo(dir, termsFile).hits, []);
});

test('positive control: a missing terms file skips cleanly rather than failing', () => {
  const { skipped, hits } = checkRepo(REPO_ROOT, '/nonexistent/terms.local.txt');
  assert.equal(skipped, true);
  assert.deepEqual(hits, []);
});
