// fitband.js — how a pinch passes the fit-width zoom, the way Freenotes does it. There is no pull and no
// animation: the sheet simply skips a band of zoom around fit-width. Pinching in, it follows your fingers
// until they reach the band's lower edge, then jumps to fit-width and stays there while your fingers cross the band;
// when they leave it at the upper edge it jumps on to where they are. Pinching out is the same the other
// way round. Fit-width is easy to land on, and nothing is slow or sticky. Plain ES module.
//
// Freenotes fits a note at 144% and skips 135% to 155% (checked against the app on the iPad): so here the band is
// the same share of whatever fit-width is on this screen.

export const BAND_LOW = 135 / 144;   // the band starts at this share of fit-width...
export const BAND_HIGH = 155 / 144;  // ...and ends at this share

/** [low, high]: the zooms that are skipped, for a fit-width zoom of `fit`. */
export const bandOf = fit => [fit * BAND_LOW, fit * BAND_HIGH];

/** Whether `zoom` lies in the skipped band. */
export const inBand = (zoom, fit) => { const [low, high] = bandOf(fit); return zoom >= low && zoom <= high; };

/** The sheet's zoom while the fingers' is `v`: `rest` (fit-width) anywhere in the band, `v` outside it. */
export const throughBand = (v, fit, rest = fit) => (inBand(v, fit) ? rest : v);
