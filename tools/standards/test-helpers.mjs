// Test-only helper: builds a throwaway git repo with a base commit and a
// branch commit, so a standards check can be mutation-tested against a
// SYNTHETIC history rather than this repo's real one. Mutating the real repo
// to prove a checker works would mean committing the very violations the
// checker exists to catch — this sidesteps that by never touching
// tools/standards against anything but a scratch fixture.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

function run(cwd, args) {
  execFileSync('git', args, { cwd, encoding: 'utf8' });
}

// files: { 'relative/path.txt': 'content' }
export function makeBaseRepo(files = { 'README.md': 'base\n' }) {
  const dir = mkdtempSync(path.join(tmpdir(), 'rni-standards-'));
  run(dir, ['init', '-q', '-b', 'main']);
  run(dir, ['config', 'user.email', 'test@example.invalid']);
  run(dir, ['config', 'user.name', 'Standards Test']);
  for (const [rel, content] of Object.entries(files)) {
    const full = path.join(dir, rel);
    mkdirSync(path.dirname(full), { recursive: true });
    writeFileSync(full, content);
  }
  run(dir, ['add', '-A']);
  run(dir, ['commit', '-q', '-m', 'chore: base']);
  run(dir, ['checkout', '-q', '-b', 'feat/scratch']);
  return dir;
}

// Adds/overwrites files and commits them with the given subject, on the
// currently checked-out branch.
export function commitFiles(dir, files, subject) {
  for (const [rel, content] of Object.entries(files)) {
    const full = path.join(dir, rel);
    mkdirSync(path.dirname(full), { recursive: true });
    writeFileSync(full, content);
  }
  run(dir, ['add', '-A']);
  run(dir, ['commit', '-q', '-m', subject]);
}
