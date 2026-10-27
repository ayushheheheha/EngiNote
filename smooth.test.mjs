// A check of the stroke smoothing in ink.js (run: node smooth.test.mjs). No framework: it throws if something is wrong.
import { strokeData } from './ink.js';

const assert = (ok, what) => { if (!ok) throw new Error('FAILED: ' + what); };
const numbers = d => d.match(/-?\d+(\.\d+)?/g).map(Number);
// The points a path's data passes through: M x y, then each Q's end point, then L's.
function ends(d) {
  const out = [];
  for (const m of d.matchAll(/([MQL])([^MQL]*)/g)) {
    const n = numbers(m[2]);
    out.push(n.slice(-2));
  }
  return out;
}
let seed = 7;
const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647 - 0.5;
const roughness = pts => {
  let sum = 0;
  for (let i = 1; i < pts.length - 1; i++) sum += (pts[i - 1][0] - 2 * pts[i][0] + pts[i + 1][0]) ** 2 + (pts[i - 1][1] - 2 * pts[i][1] + pts[i + 1][1]) ** 2;
  return Math.sqrt(sum / (pts.length - 2));
};

// A shaky straight line: much less shaky once drawn, and its ends where they were.
const line = Array.from({ length: 60 }, (_, i) => [i * 2 + rnd() * 1.5, 100 + rnd() * 3]);
const drawnLine = ends(strokeData({ tool: 'pen', color: '#000', size: 2, points: line }));
assert(roughness(drawnLine) < roughness(line) / 3, 'a shaky line comes out much smoother');
assert(Math.abs(drawnLine[0][0] - line[0][0]) < 0.01 && Math.abs(drawnLine.at(-1)[0] - line.at(-1)[0]) < 0.01, 'its ends stay put');

// An L with a sharp corner: the corner is still a corner (no rounding of its tip).
const L = [...Array.from({ length: 30 }, (_, i) => [10, i * 2 + rnd() * 0.4]), ...Array.from({ length: 30 }, (_, i) => [10 + i * 2, 58 + rnd() * 0.4])];
const drawnL = ends(strokeData({ tool: 'pen', color: '#000', size: 2, points: L }));
const tip = drawnL.reduce((best, p) => (Math.hypot(p[0] - 10, p[1] - 58) < Math.hypot(best[0] - 10, best[1] - 58) ? p : best));
assert(Math.hypot(tip[0] - 10, tip[1] - 58) < 1.2, 'a corner stays sharp');

// A short stroke (a dot, a tick) is drawn as it is.
const dot = [[5, 5], [5.5, 5.2], [6, 5.1]];
assert(strokeData({ tool: 'pen', color: '#000', size: 2, points: dot }) === 'M5 5Q5.5 5.2 5.75 5.15L6 5.1', 'a short stroke is untouched');

// Pressure is carried through smoothed, never invented: a flow stroke still gives an outline.
const flow = Array.from({ length: 40 }, (_, i) => [i * 2, 50 + Math.sin(i / 5) * 8 + rnd(), 0.5 + rnd() * 0.3]);
assert(strokeData({ tool: 'flow', color: '#000', size: 3, points: flow }).endsWith('Z'), 'a flow stroke is still an outline');
console.log('smooth.test.mjs: all checks passed');
