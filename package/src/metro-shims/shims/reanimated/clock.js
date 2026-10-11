'use strict';
// SC-26. The one JS-thread frame loop behind every animation in the
// reanimated stub. requestAnimationFrame on impeller is a setTimeout(0), so a
// rAF loop busy-spins the JS thread; frames are paced with setTimeout(16) and
// timed with performance.now(). The loop stops when nothing animates, so an
// idle app holds no timer (headless captures wait for JS idle).
const FRAME_MS = 16;
const subscribers = new Set();
let timer = null;

function now() {
  return typeof performance !== 'undefined' && performance.now ? performance.now() : Date.now();
}

function tick() {
  timer = null;
  const t = now();
  for (const fn of Array.from(subscribers)) {
    let keep = false;
    try {
      keep = fn(t);
    } catch (e) {
      console.error(e);
    }
    if (!keep) subscribers.delete(fn);
  }
  schedule();
}

function schedule() {
  if (timer == null && subscribers.size > 0) timer = setTimeout(tick, FRAME_MS);
}

// fn(now) runs once per frame while it returns true.
function onFrame(fn) {
  subscribers.add(fn);
  schedule();
  return () => subscribers.delete(fn);
}

module.exports = {now, onFrame};
