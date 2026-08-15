/**
 * Self-test for the engine resolver.
 *
 * Runs as `npm test` INSIDE THE PUBLISHED PACKAGE, which is the point: it is
 * the one check a user can run on the artifact they actually installed, on a
 * machine we have never seen. So it must depend on nothing but this package —
 * no dev dependencies, no test runner, no network, no engine binary.
 *
 * package.json declared this script for the whole of P1-P6 while the file did
 * not exist; `npm test` died with MODULE_NOT_FOUND. tools/ci-release-meta.sh
 * now fails the build when a declared entry point is missing.
 */
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const {resolveEngine, hostTriple, packageNameFor, binaryFileName, SUPPORTED} =
  require('./resolve');

let passed = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`  ok  ${name}`);
    passed++;
  } catch (e) {
    console.error(`  FAIL ${name}\n       ${e.message}`);
    process.exitCode = 1;
  }
}

console.log('@react-native-impeller/core selftest');

check('host triple is platform-arch', () => {
  assert.strictEqual(hostTriple('linux', 'x64'), 'linux-x64');
  assert.strictEqual(hostTriple('win32', 'x64'), 'win32-x64');
});

check('engine package name is derived from the triple', () => {
  assert.strictEqual(
    packageNameFor('linux-x64'),
    '@react-native-impeller/engine-linux-x64'
  );
});

check('binary name is .exe only on win32', () => {
  assert.strictEqual(binaryFileName('linux'), 'rn-impeller');
  assert.strictEqual(binaryFileName('darwin'), 'rn-impeller');
  assert.strictEqual(binaryFileName('win32'), 'rn-impeller.exe');
});

check('every SUPPORTED triple names a real optionalDependency', () => {
  // The defect this guards: a triple advertised as supported with no package
  // published. npm SKIPS a missing optional dependency and exits 0, so the
  // user gets a silent no-engine install and then an error instructing them to
  // install something that does not exist.
  const pkg = require('../package.json');
  const opt = Object.keys(pkg.optionalDependencies || {});
  for (const triple of SUPPORTED) {
    assert.ok(
      opt.includes(packageNameFor(triple)),
      `${triple} is SUPPORTED but ${packageNameFor(triple)} is not an optionalDependency`
    );
  }
});

check('every engine optionalDependency is pinned exactly, never a range', () => {
  // The engine exposes an unstable C ABI. A ^ or ~ range lets npm resolve a
  // newer engine against an older host, which crashes at runtime rather than
  // failing to install.
  const pkg = require('../package.json');
  for (const [name, spec] of Object.entries(pkg.optionalDependencies || {})) {
    assert.strictEqual(spec, pkg.version, `${name} is pinned '${spec}', expected '${pkg.version}'`);
  }
});

check('an unsupported triple is refused, and names the escape hatch', () => {
  assert.throws(
    () => resolveEngine({platform: 'sunos', arch: 'sparc', env: {}}),
    (e) =>
      /no published engine build for sunos-sparc/.test(e.message) &&
      /IMPELLER_ENGINE_BINARY/.test(e.message)
  );
});

check('IMPELLER_ENGINE_BINARY overrides the installed package', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'rni-selftest-'));
  const fake = path.join(tmp, 'rn-impeller');
  fs.writeFileSync(fake, '');
  try {
    const r = resolveEngine({env: {IMPELLER_ENGINE_BINARY: fake}});
    assert.strictEqual(r.source, 'env');
    assert.strictEqual(r.binary, fake);
  } finally {
    fs.rmSync(tmp, {recursive: true, force: true});
  }
});

check('a missing IMPELLER_ENGINE_BINARY fails loudly, not silently', () => {
  // "Cannot find it" and "using the default" must never share an outcome: an
  // override that silently falls back would run a DIFFERENT engine than the
  // developer asked for, which is the hardest kind of bug to see.
  assert.throws(
    () => resolveEngine({env: {IMPELLER_ENGINE_BINARY: '/nonexistent/rn-impeller'}}),
    /no file exists there/
  );
});

console.log(
  process.exitCode
    ? 'SELFTEST_FAIL'
    : `SELFTEST_PASS (${passed} checks)`
);
