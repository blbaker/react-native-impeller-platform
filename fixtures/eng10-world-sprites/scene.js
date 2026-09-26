/**
 * ENG-10 world-sprites gate — SHARED SCENE.
 *
 * One deterministic scene, rendered two ways by the gate:
 *   index.js           -> terrain via setPixels + sprites via GPU drawSprites
 *   reference-index.js -> the SAME terrain + sprites composited on the CPU
 *                         (compositeOnCpu below) and pushed through the proven
 *                         ENG-09 setPixels path as ONE buffer.
 * Same inputs, two paths: a correct drawSprites is byte-identical to the
 * reference modulo 8-bit blend rounding.
 *
 * ⛔ MUTANT-VACUITY GUARDS (the fixture is built so each mutant CAN fail):
 *   - M-order: neighbouring sprites OVERLAP (lattice step < sprite size) and
 *     neighbours always use DIFFERENT atlas entries of DIFFERENT luma, so
 *     reversing draw order changes every overlap strip. A per-pixel compare
 *     sees it; a histogram mostly would not.
 *   - M-atlas: 4 visually distinct atlas entries are all drawn; drawing the
 *     wrong one anywhere changes those pixels.
 *   - M-flip: every atlas entry is VERTICALLY ASYMMETRIC (different top vs
 *     bottom rows), so an upside-down sprite differs from the upright one.
 *   - M-alpha: every 5th sprite has alpha 0.5 over a non-flat background.
 *   - M-premul: the 'shadow' entry is semi-transparent (texel alpha 128).
 *
 * All sprites draw at their texture's NATIVE size at integer positions, so
 * linear sampling is 1:1 texel-to-pixel and the CPU oracle needs no filter.
 */
'use strict';

const WIDTH = 320;
const HEIGHT = 240;

// Terrain: a horizontal ramp plus a vertical band pattern. Opaque. Non-flat so
// half-alpha sprites and the shadow blend against a varying background.
function terrainLuma(x, y) {
  return 60 + Math.floor((x * 100) / WIDTH) + ((y >> 3) & 1) * 20;
}

function buildTerrain() {
  const buf = new ArrayBuffer(WIDTH * HEIGHT * 4);
  const b = new Uint8Array(buf);
  for (let y = 0; y < HEIGHT; y++) {
    for (let x = 0; x < WIDTH; x++) {
      const o = (y * WIDTH + x) * 4;
      const l = terrainLuma(x, y);
      b[o] = l;
      b[o + 1] = l;
      b[o + 2] = l;
      b[o + 3] = 255;
    }
  }
  return buf;
}

// Atlas entries: STRAIGHT (non-premultiplied) RGBA8, top-to-bottom. Each is
// a function of (row) only, and top != bottom (vertical asymmetry).
const ATLAS = {
  'peep-light': {w: 24, h: 24, px: (r) => (r < 12 ? [240, 240, 240, 255] : [90, 90, 90, 255])},
  'peep-dark': {w: 24, h: 24, px: (r) => (r < 8 ? [20, 20, 20, 255] : [170, 170, 170, 255])},
  // Coloured so an R/B channel swap changes luma (weights 299 vs 114).
  bubble: {w: 16, h: 16, px: (r) => (r < 8 ? [220, 60, 30, 255] : [30, 60, 220, 255])},
  // Semi-transparent AND tinted: exercises premultiplication. (Pure black would
  // make M-premul vacuous -- premultiplying 0 is still 0.) Asymmetric alpha.
  shadow: {w: 24, h: 10, px: (r) => (r < 5 ? [60, 30, 140, 128] : [60, 30, 140, 64])},
};
const ATLAS_IDS = Object.keys(ATLAS);

function buildAtlasEntry(id) {
  const {w, h, px} = ATLAS[id];
  const buf = new ArrayBuffer(w * h * 4);
  const b = new Uint8Array(buf);
  for (let r = 0; r < h; r++) {
    const c = px(r);
    for (let x = 0; x < w; x++) {
      const o = (r * w + x) * 4;
      b[o] = c[0];
      b[o + 1] = c[1];
      b[o + 2] = c[2];
      b[o + 3] = c[3];
    }
  }
  return buf;
}

// Back-to-front sprite list. 14x9 lattice, step 20x22 with 24x24 peeps:
// horizontal neighbours overlap 4px, vertical 2px. Shadows go down FIRST
// (under their peep) and reach into the next row. (col+row)%3 guarantees
// horizontal AND vertical neighbours use different entries.
function buildSprites() {
  const out = [];
  const kinds = ['peep-light', 'peep-dark', 'bubble'];
  const peeps = [];
  for (let row = 0; row < 9; row++) {
    for (let col = 0; col < 14; col++) {
      const i = row * 14 + col;
      const textureId = kinds[(col + row) % 3];
      const {w, h} = ATLAS[textureId];
      const x = 16 + col * 20;
      const y = 12 + row * 22;
      if (i % 7 === 3) {
        out.push({textureId: 'shadow', x, y: y + h - 4, w: 24, h: 10});
      }
      peeps.push({textureId, x, y, w, h, alpha: i % 5 === 0 ? 0.5 : 1});
    }
  }
  // Interleave: each peep after any shadows that precede it keeps paint order
  // meaningful for both shadows and peeps.
  const merged = [];
  let s = 0;
  for (let k = 0; k < peeps.length; k++) {
    if (k % 7 === 3) merged.push(out[s++]);
    merged.push(peeps[k]);
  }
  // One sprite hanging off the bottom-right corner: exercises the node clip.
  merged.push({textureId: 'peep-dark', x: WIDTH - 12, y: HEIGHT - 12, w: 24, h: 24});
  return merged;
}

// CPU oracle: premultiplied src-over, back-to-front, quantised to 8 bits after
// EVERY sprite (the GPU writes an 8-bit target per draw). Premultiply mirrors
// WorldRasterModule::registerSpriteHost exactly: (c*a + 127) / 255, integer.
function compositeOnCpu(sprites) {
  const buf = buildTerrain();
  const d = new Uint8Array(buf);
  const pre = {};
  for (const id of ATLAS_IDS) {
    const src = new Uint8Array(buildAtlasEntry(id));
    const p = new Uint8Array(src.length);
    for (let i = 0; i < src.length; i += 4) {
      const a = src[i + 3];
      p[i] = a === 255 ? src[i] : Math.floor((src[i] * a + 127) / 255);
      p[i + 1] = a === 255 ? src[i + 1] : Math.floor((src[i + 1] * a + 127) / 255);
      p[i + 2] = a === 255 ? src[i + 2] : Math.floor((src[i + 2] * a + 127) / 255);
      p[i + 3] = a;
    }
    pre[id] = p;
  }
  for (const s of sprites) {
    const tex = pre[s.textureId];
    const tw = ATLAS[s.textureId].w;
    const alpha = s.alpha == null ? 1 : s.alpha;
    for (let ty = 0; ty < s.h; ty++) {
      const dy = s.y + ty;
      if (dy < 0 || dy >= HEIGHT) continue;
      for (let tx = 0; tx < s.w; tx++) {
        const dx = s.x + tx;
        if (dx < 0 || dx >= WIDTH) continue;
        const so = (ty * tw + tx) * 4;
        const o = (dy * WIDTH + dx) * 4;
        const sa = (tex[so + 3] / 255) * alpha;
        for (let c = 0; c < 3; c++) {
          const sc = (tex[so + c] / 255) * alpha;
          const v = sc + (d[o + c] / 255) * (1 - sa);
          d[o + c] = Math.max(0, Math.min(255, Math.round(v * 255)));
        }
        d[o + 3] = 255;
      }
    }
  }
  return buf;
}

module.exports = {
  WIDTH,
  HEIGHT,
  ATLAS,
  ATLAS_IDS,
  buildTerrain,
  buildAtlasEntry,
  buildSprites,
  compositeOnCpu,
};
