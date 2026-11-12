// motion.js: how one screen gives way to another. A note opens out of the card that was tapped and settles
// with a little spring, as in Files and Notes; going back, the library settles in. Plain Web Animations on
// `transform` and `opacity` only (never on an individual translate/scale: the iPad drops a transform that
// shares an element with one, see the note on that in the project memory), so the page is never re-laid out.
//
// Nothing here may get in the way: with "reduce motion" on, or a browser without Web Animations or linear()
// easing, the screen simply changes, as it did before.

const still = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

/** A damped spring as a CSS linear() easing: it runs 0 to 1 over the whole duration, a few percent past 1, and comes
    to rest. `damping` 1 would never overshoot; a lower one rings more. */
export function spring(damping = 0.72, steps = 36) {
  const w = 6.5, wd = w * Math.sqrt(1 - damping * damping);
  const at = t => 1 - Math.exp(-damping * w * t) * (Math.cos(wd * t) + (damping * w / wd) * Math.sin(wd * t));
  const points = [];
  for (let i = 0; i < steps; i++) points.push(at(i / steps).toFixed(4));
  points.push('1');
  return `linear(${points.join(', ')})`;
}
const EASING = spring();
const SUPPORTED = typeof CSS !== 'undefined' && CSS.supports?.('transition-timing-function', 'linear(0, 1)');

/** `el` (the screen being opened, already visible) grows out of `from`, a DOMRect (the card tapped), or, with none, rises a little out of the middle. */
export function zoomIn(el, from) {
  if (!SUPPORTED || !el.animate || still()) return;
  const to = el.getBoundingClientRect();
  if (!to.width || !to.height) return;
  let start = 'scale(.94)';
  if (from && from.width > 0 && from.height > 0 && from.bottom > 0 && from.right > 0 && from.top < innerHeight && from.left < innerWidth) {
    const dx = from.left + from.width / 2 - (to.left + to.width / 2), dy = from.top + from.height / 2 - (to.top + to.height / 2);
    start = `translate(${dx}px, ${dy}px) scale(${Math.max(0.05, from.width / to.width)})`;
  }
  el.animate([{ transform: start }, { transform: 'none' }], { duration: 520, easing: EASING });
  el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 160, easing: 'ease-out' });
}

/** `el` (the screen being returned to, already visible) settles in from a hair too large, like a view coming back to the front. */
export function settleIn(el) {
  if (!SUPPORTED || !el.animate || still()) return;
  el.animate([{ transform: 'scale(1.04)' }, { transform: 'none' }], { duration: 440, easing: EASING });
  el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 160, easing: 'ease-out' });
}
