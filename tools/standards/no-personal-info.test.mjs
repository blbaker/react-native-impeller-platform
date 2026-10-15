// Standard: "no personal hostnames/paths/IPs" — this repo's own version of
// a broader rule (don't leak the author's local machine into a public repo).
// Scans ADDED lines on this branch. Pre-existing internal engineering-log
// docs (docs/STATE.md, docs/MAC-DELIVERY.md, ...) are a one-time cleanup
// decision, tracked in docs/OPEN-SOURCE-READINESS.md — this gate is about
// NOT ADDING MORE of it going forward.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addedLinesByFile, baseRef, isOwnedPath, REPO_ROOT } from './lib.mjs';
import { makeBaseRepo, commitFiles } from './test-helpers.mjs';

const PATTERNS = [
  [/\/home\/[a-z][a-z0-9_-]*\//, 'an absolute home directory path'],
  [/\bmac-direct\b/, 'a personal ssh host alias'],
  [/\bagent-mesh\b/, 'an internal tool name'],
  [/\b192\.168\.\d{1,3}\.\d{1,3}\b/, 'a private LAN IP'],
  [/\b100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b/, 'a tailnet (CGNAT) IP'],
  [/\bdiscord:\d{17,20}\b/, 'a Discord channel/guild id'],
];

function scanLine(line) {
  const labels = [];
  for (const [re, label] of PATTERNS) {
    if (re.test(line)) labels.push(label);
  }
  return labels;
}

function checkRepo(cwd) {
  const base = baseRef(cwd);
  const hits = [];
  for (const [file, lines] of addedLinesByFile(cwd, base)) {
    if (isOwnedPath(file)) continue;
    // Same reasoning as no-secrets.test.mjs: the pattern list below has to
    // spell out the literal words it looks for (mac, the-sync-tool),
    // which would otherwise flag this very file against its own rule.
    if (file.startsWith('tools/standards/')) continue;
    for (const line of lines) {
      for (const label of scanLine(line)) hits.push({ file, label, line });
    }
  }
  return hits;
}

test('real: no personal paths/hosts/IPs added on this branch', () => {
  const hits = checkRepo(REPO_ROOT);
  if (hits.length > 0) {
    const detail = hits.map((h) => `  ${h.file}: looks like ${h.label} (${h.line.trim()})`).join('\n');
    assert.fail(`personal/internal detail(s) added on this branch:\n${detail}`);
  }
});

test('positive control: a home path and a tailnet IP are both caught', () => {
  const dir = makeBaseRepo();
  commitFiles(
    dir,
    { 'notes.md': 'Built at /home/alice/projects/thing, reachable at <tailnet-ip>\n' },
    'docs: add build notes',
  );
  const hits = checkRepo(dir);
  const labels = hits.map((h) => h.label).sort();
  assert.deepEqual(labels, ['a tailnet (CGNAT) IP', 'an absolute home directory path']);
});

test('positive control: removing the detail clears the check', () => {
  const dir = makeBaseRepo();
  commitFiles(dir, { 'notes.md': 'Built at /home/alice/projects/thing\n' }, 'docs: add build notes');
  assert.equal(checkRepo(dir).length, 1);
  commitFiles(dir, { 'notes.md': 'Built from a clean checkout.\n' }, 'docs: generalize build notes');
  assert.deepEqual(checkRepo(dir), []);
});

test('positive control: a parity-owned file is never scanned', () => {
  const dir = makeBaseRepo();
  commitFiles(
    dir,
    { 'docs/eng/flutter-parity/notes.md': 'ssh mac for the darwin build\n' },
    'parity(FP-99): notes',
  );
  assert.deepEqual(checkRepo(dir), []);
});
