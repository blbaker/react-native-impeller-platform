#!/usr/bin/env node
'use strict';
// ENG-01d static scope check. Reads a bundle + its source map and reports
// which ORIGINAL files the renamed Platform binding (`_rniRuntimePlatform`)
// landed in. The rename must hit the TextInput folder (the files withImpeller
// hands the as-ios Platform) and nothing else: anywhere else it would only
// strip DCE today, and it is the first step of a global Platform.OS lie.
//
// Usage: textinput-inline-os-scope.js <bundle> <map> [--expect-none]
// Prints TIIOS_SCOPE_PASS / TIIOS_SCOPE_FAIL: <why>. No dependencies.
const fs = require('fs');

const MARK = '_rniRuntimePlatform';
const SCOPE = /react-native\/Libraries\/Components\/TextInput\//;
const MUST = /react-native\/Libraries\/Components\/TextInput\/TextInput\.js$/;

const [bundlePath, mapPath, flag] = process.argv.slice(2);
const expectNone = flag === '--expect-none';
const fail = (why) => {
  console.log('TIIOS_SCOPE_FAIL: ' + why);
  process.exit(1);
};

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const B64_INDEX = new Map([...B64].map((c, i) => [c, i]));
function decodeSegment(seg) {
  const out = [];
  let value = 0;
  let shift = 0;
  for (const ch of seg) {
    const digit = B64_INDEX.get(ch);
    if (digit === undefined) throw new Error('bad VLQ char ' + ch);
    value += (digit & 31) << shift;
    if (digit & 32) {
      shift += 5;
    } else {
      out.push(value & 1 ? -(value >>> 1) : value >>> 1);
      value = 0;
      shift = 0;
    }
  }
  return out;
}

// generated line (0-based) -> set of source indices mapped on that line
function sourcesByLine(map) {
  const lines = map.mappings.split(';');
  const result = [];
  let src = 0;
  for (const line of lines) {
    const seen = new Set();
    if (line) {
      for (const seg of line.split(',')) {
        const f = decodeSegment(seg);
        if (f.length >= 4) {
          src += f[1];
          seen.add(src);
        }
      }
    }
    result.push(seen);
  }
  return result;
}

const code = fs.readFileSync(bundlePath, 'utf8').split('\n');
const map = JSON.parse(fs.readFileSync(mapPath, 'utf8'));
if (!map.mappings) fail('source map has no mappings (sectioned map not supported)');
const byLine = sourcesByLine(map);
const hits = new Map(); // source -> count
code.forEach((text, i) => {
  if (!text.includes(MARK)) return;
  const srcs = byLine[i] || new Set();
  if (srcs.size === 0) {
    hits.set('<unmapped line ' + (i + 1) + '>', 1);
    return;
  }
  for (const s of srcs) {
    const name = String(map.sources[s]).split('\\').join('/');
    hits.set(name, (hits.get(name) || 0) + 1);
  }
});

for (const [name, n] of hits) console.log('tiios_scope_hit ' + n + ' ' + name.replace(/^.*node_modules\//, ''));
if (expectNone) {
  if (hits.size) fail(hits.size + ' file(s) carry ' + MARK + ' in a bundle that must not');
  console.log('TIIOS_SCOPE_PASS none');
  process.exit(0);
}
const outside = [...hits.keys()].filter((n) => !SCOPE.test(n));
if (outside.length) fail(MARK + ' outside the TextInput folder: ' + outside.join(', '));
if (![...hits.keys()].some((n) => MUST.test(n))) fail(MARK + ' missing from TextInput.js');
console.log('TIIOS_SCOPE_PASS files=' + hits.size);
