// Shared helpers for tools/standards/*.test.mjs.
//
// Every check here runs against the current BRANCH'S DIFF against a base
// ref (default: origin/main, overridable via RNI_STANDARDS_BASE), not the
// whole repo. Retroactively failing on pre-existing engineering-log docs
// (docs/STATE.md, docs/eng/*) would block unrelated work for debt this
// suite did not create; scoping to the diff keeps the check meaningful for
// new work without demanding a one-time mass cleanup as a side effect.

import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export const REPO_ROOT = path.resolve(fileURLToPath(new URL('.', import.meta.url)), '..', '..');

export function git(args, opts = {}) {
  return execFileSync('git', args, {
    cwd: opts.cwd || REPO_ROOT,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024 * 64,
    // Probing for an optional base ref (baseRef()) deliberately tries refs
    // that may not exist and relies on the throw, not the printed message —
    // suppress git's own stderr so a clean test run isn't full of expected
    // "fatal: Needed a single revision" noise from that probing.
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

export function baseRef(cwd) {
  const want = process.env.RNI_STANDARDS_BASE || 'origin/main';
  for (const candidate of [want, 'main', 'HEAD~1']) {
    try {
      git(['rev-parse', '--verify', candidate], { cwd });
      return candidate;
    } catch {
      continue;
    }
  }
  return 'HEAD';
}

// Parsed unified diff: only ADDED lines, keyed by file. Deleted lines and
// context lines are not scanned — this suite checks what a branch is
// INTRODUCING, not what it inherited.
export function addedLinesByFile(cwd, base = baseRef(cwd)) {
  const raw = git(['diff', '--unified=0', `${base}...HEAD`, '--'], { cwd });
  const files = new Map();
  let current = null;
  for (const line of raw.split('\n')) {
    if (line.startsWith('+++ b/')) {
      current = line.slice(6);
      if (!files.has(current)) files.set(current, []);
    } else if (line.startsWith('+++ /dev/null')) {
      current = null;
    } else if (current && line.startsWith('+') && !line.startsWith('+++')) {
      files.get(current).push(line.slice(1));
    }
  }
  return files;
}

// Files newly ADDED on this branch (not modified — a modified 400-line file
// that was already 400 lines is pre-existing debt, not a new violation).
export function addedFiles(cwd, base = baseRef(cwd)) {
  const raw = git(['diff', '--name-status', `${base}...HEAD`, '--'], { cwd });
  return raw
    .split('\n')
    .filter((l) => l.startsWith('A\t'))
    .map((l) => l.slice(2));
}

export function commitSubjects(cwd, base = baseRef(cwd)) {
  const raw = git(['log', '--format=%s', `${base}..HEAD`], { cwd });
  return raw.split('\n').filter(Boolean);
}

// Paths this suite must never flag: they belong to the live Flutter-parity
// automation and are explicitly off limits to edit.
const OWNED_PREFIXES = ['docs/eng/flutter-parity/', 'tools/parity-'];

export function isOwnedPath(p) {
  return OWNED_PREFIXES.some((prefix) => p.startsWith(prefix));
}
