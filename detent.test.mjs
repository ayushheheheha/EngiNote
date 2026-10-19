// Checks for detent.js: `node detent.test.mjs`. Prints one line per failure and exits 1 if there is any.
import { detent, undetent, STUCK, EASE } from './detent.js';

let bad = 0;
const check = (name, cond, extra = '') => { if (!cond) { bad++; console.log(`FAIL ${name} ${extra}`); } };
const near = (a, b, tol = 1e-9) => Math.abs(a - b) < tol;

// held still in the middle
for (const d of [0, 0.01, -0.02, STUCK, -STUCK]) check(`held at ${d}`, detent(d) === 0, String(detent(d)));
// no jump anywhere: a tiny step in d is a tiny step in y, and never more than the step itself
let last = detent(-0.5), worst = 0;
for (let d = -0.5 + 1e-4; d <= 0.5; d += 1e-4) {
  const y = detent(d);
  worst = Math.max(worst, Math.abs(y - last));
  check(`monotone at ${d.toFixed(4)}`, y >= last - 1e-12);
  last = y;
}
check('never faster than the fingers, no jumps', worst <= 1e-4 + 1e-9, String(worst));
// out in the open the sheet moves one for one with the fingers, a fixed distance behind
for (const d of [0.2, 0.5, -0.3]) check(`same speed at ${d}`, near(Math.abs(detent(d + 0.01) - detent(d)), 0.01));
check('lag is the zone\'s worth', near(0.5 - detent(0.5), STUCK + (EASE - STUCK) / 2));
// symmetric in and out
check('symmetric', near(detent(-0.07), -detent(0.07)));
// slower than the fingers while easing
check('slower while easing', detent(0.06) - detent(0.05) < 0.01);
// the other way round
for (const y of [0, 0.001, 0.02, 0.0449, 0.045, 0.2, -0.001, -0.3]) check(`undetent(${y}) round trip`, near(detent(undetent(y)), y, 1e-9), String(detent(undetent(y))));
check('undetent of nothing is nothing', undetent(0) === 0);
// continuity of the slope at the join: just inside and just outside EASE move alike
check('slope joins at EASE', near(detent(EASE + 1e-6) - detent(EASE), detent(EASE) - detent(EASE - 1e-6), 1e-6));

console.log(bad ? `${bad} failed` : 'all passed');
process.exit(bad ? 1 : 0);
