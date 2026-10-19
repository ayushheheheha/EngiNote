// detent.js — the soft hold at the fit-width zoom. While two fingers pinch, the sheet follows them,
// except near fit-width, where it slows down, stops, and lets go again without a jump: the sheet is
// "caught" and you feel the width go by. Plain ES module, all in log zoom (so in and out feel alike).
//
//   d: how far the fingers' zoom is from fit-width.   y: how far the sheet's zoom is.
//
//   |d| up to STUCK       the sheet does not move (y = 0)
//   STUCK to EASE         it moves slower than the fingers, and gets up to their speed
//   beyond EASE           it moves with them, a fixed distance behind (the zone's worth, STUCK + half)
//
// The curve is continuous, with a continuous slope, so there is nothing to see at its joins.

export const STUCK = 0.03; // 3% either side of fit-width: held still
export const EASE = 0.12;  // out to 12%: easing back to the fingers' speed
const HALF = (EASE - STUCK) / 2;

/** The sheet's distance from fit-width for the fingers' (both signed). */
export function detent(d) {
  const a = Math.abs(d);
  const y = a <= STUCK ? 0 : a >= EASE ? a - STUCK - HALF : (a - STUCK) ** 2 / (2 * (EASE - STUCK));
  return Math.sign(d) * y;
}

/** The fingers' distance that puts the sheet at `y`: the other way round. (Inside the held zone, which is every d at y = 0, its edge.) */
export function undetent(y) {
  const a = Math.abs(y);
  const d = a <= 0 ? 0 : a >= HALF ? a + STUCK + HALF : STUCK + Math.sqrt(2 * (EASE - STUCK) * a);
  return Math.sign(y) * d;
}
