// Checks for fitband.js: `node fitband.test.mjs`. Prints one line per failure and exits 1 if there is any.
import { bandOf, inBand, throughBand, BAND_LOW, BAND_HIGH } from './fitband.js';

let bad = 0;
const check = (name, cond, extra = '') => { if (!cond) { bad++; console.log(`FAIL ${name} ${extra}`); } };

// On Freenotes' own numbers (fit-width 144%) the band is 135% to 155%.
const [low, high] = bandOf(1.44);
check('lower edge is 135%', Math.abs(low - 1.35) < 1e-9, String(low));
check('upper edge is 155%', Math.abs(high - 1.55) < 1e-9, String(high));
check('shares', BAND_LOW < 1 && BAND_HIGH > 1);

// Pinching in slowly from 100%: follows the fingers up to the band, sits on fit through it, follows again past it.
const shown = [];
for (let v = 1.0; v <= 1.8; v += 0.001) shown.push([v, throughBand(v, 1.44)]);
for (const [v, z] of shown) {
  if (v < 1.349) check(`follows below the band at ${v.toFixed(3)}`, z === v);
  else if (v > 1.401 && v < 1.549) check(`held at fit inside the band at ${v.toFixed(3)}`, z === 1.44);
  else if (v > 1.551) check(`follows above the band at ${v.toFixed(3)}`, z === v);
}
// The jumps, and only those: one on the way in (to fit-width), one on the way out (to the fingers).
let jumps = 0;
for (let i = 1; i < shown.length; i++) if (Math.abs(shown[i][1] - shown[i - 1][1]) > 0.01) jumps++;
check('exactly two jumps across the band', jumps === 2, String(jumps));
// The sheet never shows a zoom inside the band, other than fit-width itself.
for (const [, z] of shown) check('nothing inside the band but fit', !inBand(z, 1.44) || z === 1.44, String(z));

// Pinching out is the same curve read backwards: from above the band, down.
check('out: above stays', throughBand(1.6, 1.44) === 1.6);
check('out: into the band is fit', throughBand(1.5, 1.44) === 1.44);
check('out: below the band follows', throughBand(1.3, 1.44) === 1.3);
// A pinch that began inside the band on a zoom that is not fit-width rests there (the `rest` argument).
check('rest', throughBand(1.4, 1.44, 1.4) === 1.4 && throughBand(1.7, 1.44, 1.4) === 1.7);

if (bad) { console.log(`${bad} failed`); process.exit(1); }
console.log('fitband.test.mjs: all checks passed');
