// ghost.js — a faint shadow of the stylus on the page while it hovers: the pen's own shape, lying
// from the tip back the way the pen leans, so you can see where your hand is as well as the tip.
// Plain ES module. It only watches the pointer; it changes nothing.
//
// It follows what the stylus reports: azimuthAngle (which way the pen's far end points on the
// screen, in radians, 0 being to the right and growing clockwise) and altitudeAngle (π/2 upright,
// 0 lying flat). A browser that reports neither gets a pen leaning up and to the right.

const LEAN = -0.8;       // rad: where the pen points when the device does not say (up and right, as a right hand holds it)
const UPRIGHT = 0.9;     // rad: how upright it is, likewise
const SHORTEST = 0.4;    // a pen standing straight up casts this much of its length
const GONE_AFTER = 5000; // ms: a hovering stylus that has gone out of range without a word is let go of after this

const SVG = '<svg width="190" height="26" viewBox="0 -13 190 26" aria-hidden="true"><defs>' +
  '<linearGradient id="ghost-fade" x1="0" x2="1"><stop offset="0" stop-color="currentColor" stop-opacity=".38"/><stop offset="1" stop-color="currentColor" stop-opacity=".07"/></linearGradient></defs>' +
  '<path d="M0 0L20-4.2 28-6H176Q188-6 188 0Q188 6 176 6H28L20 4.2Z" fill="url(#ghost-fade)"/></svg>';

/** `surface`: the element the stylus hovers over. Returns { enable(on), dark(on) }: whether to show it at all, and whether the page is dark (the shadow is then light). */
export function createGhost(surface) {
  const el = document.createElement('div');
  el.id = 'pen-ghost';
  el.innerHTML = SVG;
  el.setAttribute('aria-hidden', 'true');
  document.body.append(el);
  let on = true, timer = 0;

  const hide = () => { el.style.opacity = '0'; clearTimeout(timer); };
  function show(e) {
    // A pen that reports no tilt is given as straight up and pointing right (the specification's own defaults): that is no information.
    const known = Number.isFinite(e.azimuthAngle) && Number.isFinite(e.altitudeAngle) && !(e.azimuthAngle === 0 && Math.abs(e.altitudeAngle - Math.PI / 2) < 0.001);
    const az = known ? e.azimuthAngle : LEAN, alt = known ? e.altitudeAngle : UPRIGHT;
    const length = SHORTEST + (1 - SHORTEST) * Math.cos(alt); // upright: short; lying down: all of it
    el.style.transform = `translate(${e.clientX}px, ${e.clientY}px) rotate(${az}rad) scale(${length.toFixed(3)}, 1)`;
    el.style.opacity = '1';
    clearTimeout(timer);
    timer = setTimeout(hide, GONE_AFTER);
  }

  surface.addEventListener('pointermove', e => {
    if (e.pointerType !== 'pen') return;
    if (on && e.buttons === 0) show(e); // hovering; once it touches, the ink is what to look at
    else hide();
  }, { passive: true });
  surface.addEventListener('pointerdown', e => { if (e.pointerType === 'pen') hide(); }, { passive: true });
  for (const type of ['pointerleave', 'pointercancel']) surface.addEventListener(type, hide, { passive: true });

  return {
    enable(value) { on = !!value; if (!on) hide(); },
    dark(value) { el.dataset.dark = value ? '1' : ''; },
  };
}
