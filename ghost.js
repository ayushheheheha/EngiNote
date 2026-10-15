// ghost.js — a faint shadow of the stylus on the page while it hovers: the pen's own shape, lying
// from the tip back the way the pen leans, so you can see where your hand is as well as the tip.
// Plain ES module. It only watches the pointer; it changes nothing.
//
// Two sources, the better one used when there is one:
//  - The iPad app (ios/App/NoteViewController.swift) reports the hovering Apple Pencil as 'pencilhover'
//    events on the window: where it is, which way it leans (azimuth, altitude), how far it is rolled
//    (the Pencil Pro's barrel roll) and how high above the screen it is (0 touching, 1 as high as it
//    hovers). A web page is told none of the last two, and a web view not always the first.
//  - Otherwise the page's own pointer events, which carry azimuthAngle and altitudeAngle where a browser
//    reports them. A browser that reports neither gets a pen leaning up and to the right.
//
// azimuth: which way the pen's far end points on the screen, in radians, 0 to the right and growing
// clockwise. altitude: π/2 upright, 0 lying flat.

const LEAN = -0.8;       // rad: where the pen points when the device does not say (up and right, as a right hand holds it)
const UPRIGHT = 0.9;     // rad: how upright it is, likewise
const SHORTEST = 0.4;    // a pen standing straight up casts this much of its length
const GONE_AFTER = 60000; // ms: a hovering stylus that has gone out of range without a word is let go of after this (a held-still pen sends nothing, so not short)
const NATIVE_FOR = 1200; // ms after a report from the app during which the page's own pointer events are not used

const SVG = '<svg width="190" height="26" viewBox="0 -13 190 26" aria-hidden="true"><defs>' +
  '<linearGradient id="ghost-fade" x1="0" x2="1"><stop offset="0" stop-color="currentColor" stop-opacity=".38"/><stop offset="1" stop-color="currentColor" stop-opacity=".07"/></linearGradient></defs>' +
  '<path d="M0 0L20-4.2 28-6H176Q188-6 188 0Q188 6 176 6H28L20 4.2Z" fill="url(#ghost-fade)"/>' +
  // The barrel's flat side, which slides across it as the Pencil is rolled.
  '<path id="ghost-flat" d="M34 0H172" stroke="currentColor" stroke-opacity=".22" stroke-width="2.2" stroke-linecap="round" fill="none"/></svg>';

/** `surface`: the element the stylus hovers over. Returns { enable(on), dark(on) }: whether to show it at all, and whether the page is dark (the shadow is then light). */
export function createGhost(surface) {
  const el = document.createElement('div');
  el.id = 'pen-ghost';
  el.innerHTML = SVG;
  el.setAttribute('aria-hidden', 'true');
  document.body.append(el);
  const flat = el.querySelector('#ghost-flat');
  let on = true, timer = 0, fromApp = -Infinity;

  const hide = () => { el.style.opacity = '0'; clearTimeout(timer); };

  // Put the shadow with its tip at (x, y). `lift`: 0 for the tip touching the screen, 1 for as high as it hovers.
  function draw(x, y, az, alt, roll, lift) {
    const length = SHORTEST + (1 - SHORTEST) * Math.cos(alt); // upright: short; lying down: all of it
    // The higher the pen, the further its shadow is cast from it, and the paler and softer that shadow is.
    const dx = 7 * lift, dy = 11 * lift;
    el.style.transform = `translate(${(x + dx).toFixed(1)}px, ${(y + dy).toFixed(1)}px) rotate(${az.toFixed(4)}rad) scale(${length.toFixed(3)}, 1)`;
    el.style.opacity = (1 - 0.45 * lift).toFixed(2);
    el.style.filter = `blur(${(1 + 3 * lift).toFixed(2)}px)`;
    flat.setAttribute('transform', `translate(0 ${(Math.sin(roll) * 3.4).toFixed(2)})`);
    clearTimeout(timer);
    timer = setTimeout(hide, GONE_AFTER);
  }

  // From the page's own pointer events.
  function fromPointer(e) {
    // A pen that reports no tilt is given as straight up and pointing right (the specification's own defaults): that is no information.
    const known = Number.isFinite(e.azimuthAngle) && Number.isFinite(e.altitudeAngle) && !(e.azimuthAngle === 0 && Math.abs(e.altitudeAngle - Math.PI / 2) < 0.001);
    draw(e.clientX, e.clientY, known ? e.azimuthAngle : LEAN, known ? e.altitudeAngle : UPRIGHT, 0, 0);
  }

  // Hovering or writing: the shadow follows the tip either way. While the pen is down (writing) only the page's own
  // pointer events are used, the very ones the ink is drawn from, so the shadow cannot lag or stick on an old hover report.
  let down = false;
  const follow = e => {
    if (e.pointerType !== 'pen') return;
    if (e.type === 'pointerdown') down = true;
    if (on && (down || performance.now() - fromApp >= NATIVE_FOR)) fromPointer(e);
  };
  surface.addEventListener('pointermove', follow, { passive: true });
  surface.addEventListener('pointerdown', follow, { passive: true });
  for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) surface.addEventListener(type, e => { if (e.pointerType === 'pen') down = false; }, { passive: true });
  for (const type of ['pointerleave', 'pointercancel']) surface.addEventListener(type, () => { if (!down && performance.now() - fromApp >= NATIVE_FOR) hide(); }, { passive: true });

  // From the iPad app: { x, y, az, alt, roll, z } while hovering, { end: true } when it stops.
  addEventListener('pencilhover', e => {
    if (down) return; // writing: the page's own events place the shadow
    const d = e.detail || {};
    fromApp = performance.now();
    if (d.end) fromApp = -Infinity; // the pen touched down (or left): the page's pointer events carry on from here
    if (d.end || !on || !Number.isFinite(d.x) || !Number.isFinite(d.y)) return hide();
    // Over the toolbar, a menu or anything else that is not the page: no shadow there.
    if (!surface.contains(document.elementFromPoint(d.x, d.y))) return hide();
    draw(d.x, d.y, d.az ?? LEAN, d.alt ?? UPRIGHT, d.roll ?? 0, Math.min(1, Math.max(0, d.z ?? 0)));
  });

  return {
    enable(value) { on = !!value; if (!on) hide(); },
    dark(value) { el.dataset.dark = value ? '1' : ''; },
  };
}
