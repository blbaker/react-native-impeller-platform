#!/usr/bin/env node
'use strict';
// Prints the resolved engine binary path, or a naming-the-package error on stderr.
// Used by CI gates and by consumers debugging an install.
const {resolveEngine} = require('../resolve');
try {
  const r = resolveEngine();
  process.stdout.write(r.binary + '\n');
} catch (e) {
  process.stderr.write(e.message + '\n');
  process.exit(1);
}
