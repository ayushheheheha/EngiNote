// ink.js — freehand annotation layer for EngiNote. Plain ES module, no dependencies.

const NS = 'http://www.w3.org/2000/svg';
const HIGHLIGHTER_SCALE = 5;      // highlighter width = size * this
const HIGHLIGHTER_OPACITY = 0.35;
const ERASER_RADIUS = 8;          // page px, on top of half the stroke's width
const MIN_STEP = 0.5;             // page px; closer points are dropped
const MAX_HISTORY = 100;
const CURSORS = { pen: 'crosshair', highlighter: 'crosshair', eraser: 'cell', hand: 'grab' };

// Stylus and palm tuning. Chosen without the hardware to hand: calibrate on the real device.
const PRESSURE_FLOOR = 0.35;      // width factor at zero pressure; pressure 0.5 gives exactly `size`
const PRESSURE_SMOOTH = 0.6;      // weight of the previous sample when smoothing raw pressure
const PALM_AFTER_PEN = 300;       // ms after the stylus leaves the page: a touch landing this soon is taken for the palm
const PAN_SLOP = 8;               // screen px a finger must travel before it starts to scroll or zoom
const TAP_MS = 250;               // longest a finger may stay down and still count as a tap
const DOUBLE_TAP_MS = 400;        // longest gap between the two taps of a double tap
const DOUBLE_TAP_DIST = 40;       // screen px the two taps may be apart

const round1 = n => Math.round(n * 10) / 10;
const round2 = n => Math.round(n * 100) / 100;

// ---------- pure geometry (no DOM) ----------

/** Rendered width of a stroke in page pixels (for a pressure stroke: its width at pressure 0.5). */
export function strokeWidth(stroke) {
  return stroke.tool === 'highlighter' ? stroke.size * HIGHLIGHTER_SCALE : stroke.size;
}

/** Width of a pressure-sensitive stroke where the pressure is p (0..1). */
export function widthAt(size, p) {
  return size * (PRESSURE_FLOOR + (1 - PRESSURE_FLOOR) * 2 * p);
}

// A pressure stroke has points [x, y, pressure] and is drawn as one filled outline. Its centre line
// is the same midpoint curve pathData() draws (straight from the first point to the first midpoint,
// then a curve from midpoint to midpoint bending at each point); the outline is that line pushed
// out by half the width on either side, closed with a round cap at each end.
// One closed shape per stroke matters: an earlier version stamped a disc and a quad at every step,
// hundreds of overlapping pieces per stroke, and repainting a page of those was what made erasing
// and zooming slow.
function disc([x, y, p], size) {
  const r = round2(widthAt(size, p) / 2);
  return `M${round2(x - r)} ${round2(y)}a${r} ${r} 0 1 0 ${round2(2 * r)} 0a${r} ${r} 0 1 0 ${round2(-2 * r)} 0`;
}

const mid = (a, b) => [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2];

// Unit vector square to the direction a -> b, or null where the two coincide.
function across(a, b) {
  const dx = b[0] - a[0], dy = b[1] - a[1], len = Math.hypot(dx, dy);
  return len ? [-dy / len, dx / len] : null;
}

/** Path data for a whole pressure stroke. */
export function outlineData(points, size) {
  const n = points.length;
  if (n === 1) return disc(points[0], size);
  // The point on one side (+1 or -1) of centre-line point p, where `n` is the unit vector across the line there.
  const edge = (p, n, side) => {
    const r = side * widthAt(size, p[2]) / 2;
    return `${round2(p[0] + n[0] * r)} ${round2(p[1] + n[1] * r)}`;
  };
  const NONE = [0, 0];
  // seg[i]: across the straight run from point i to point i + 1. bend[i]: across the curve where it bends at point i.
  const seg = [];
  for (let i = 0; i < n - 1; i++) seg.push(across(points[i], points[i + 1]) || seg[i - 1] || NONE);
  const bend = i => across(points[i - 1], points[i + 1]) || seg[i - 1];
  const first = points[0], last = points[n - 1];
  const cap = p => { const r = round2(widthAt(size, p[2]) / 2); return `A${r} ${r} 0 0 0 `; };

  // out along one side...
  let d = `M${edge(first, seg[0], 1)}L${edge(mid(first, points[1]), seg[0], 1)}`;
  for (let i = 1; i < n - 1; i++) d += `Q${edge(points[i], bend(i), 1)} ${edge(mid(points[i], points[i + 1]), seg[i], 1)}`;
  d += `L${edge(last, seg[n - 2], 1)}${cap(last)}${edge(last, seg[n - 2], -1)}`;
  // ...and back along the other
  d += `L${edge(mid(points[n - 2], last), seg[n - 2], -1)}`;
  for (let i = n - 2; i >= 1; i--) d += `Q${edge(points[i], bend(i), -1)} ${edge(mid(points[i - 1], points[i]), seg[i - 1], -1)}`;
  d += `L${edge(first, seg[0], -1)}${cap(first)}${edge(first, seg[0], 1)}Z`;

  // Where the line doubles back sharply the outline alone would leave a flat corner: round it with a
  // disc. The disc goes on the curve's own turning point, (a + 6b + c) / 8, not on b: the curve only
  // bends towards b, so a disc there would stick out as a knob.
  for (let i = 1; i < n - 1; i++) {
    const a = points[i - 1], b = points[i], c = points[i + 1];
    if ((b[0] - a[0]) * (c[0] - b[0]) + (b[1] - a[1]) * (c[1] - b[1]) < 0) {
      d += disc([0, 1, 2].map(k => (a[k] + 6 * b[k] + c[k]) / 8), size);
    }
  }
  return d;
}

/** Path data for any stroke: an outline to fill for a pressure stroke, a line to stroke otherwise. */
export function strokeData(stroke) {
  return stroke.points[0].length > 2 ? outlineData(stroke.points, stroke.size) : pathData(stroke.points);
}

const boxes = new WeakMap();
/** [minX, minY, maxX, maxY] of a stroke's ink. Cached: a stroke is never changed once it is committed. */
export function boxOf(stroke) {
  let box = boxes.get(stroke);
  if (!box) {
    const pressure = stroke.points[0].length > 2;
    const half = Math.max(strokeWidth(stroke), pressure ? widthAt(stroke.size, 1) : 0) / 2;
    box = [Infinity, Infinity, -Infinity, -Infinity];
    for (const [x, y] of stroke.points) {
      if (x < box[0]) box[0] = x;
      if (y < box[1]) box[1] = y;
      if (x > box[2]) box[2] = x;
      if (y > box[3]) box[3] = y;
    }
    box[0] -= half; box[1] -= half; box[2] += half; box[3] += half;
    boxes.set(stroke, box);
  }
  return box;
}

/** SVG path data for [[x, y], ...]: quadratic curves through the midpoints of successive points. */
export function pathData(points) {
  const n = points ? points.length : 0;
  if (!n) return '';
  const [x0, y0] = points[0];
  // A near-zero-length segment plus round caps renders as a dot in every browser.
  if (n === 1) return `M${x0} ${y0}l0.01 0`;
  let d = `M${x0} ${y0}`;
  for (let i = 1; i < n - 1; i++) {
    const [x, y] = points[i];
    const [nx, ny] = points[i + 1];
    d += `Q${x} ${y} ${round2((x + nx) / 2)} ${round2((y + ny) / 2)}`;
  }
  const [xe, ye] = points[n - 1];
  return `${d}L${xe} ${ye}`;
}

/** Distance from point p to the segment a-b. */
export function distToSegment(px, py, ax, ay, bx, by) {
  const dx = bx - ax, dy = by - ay;
  const len2 = dx * dx + dy * dy;
  const t = len2 ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2)) : 0;
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

/** True if (x, y) is within `radius` of the stroke's inked area. */
export function hitStroke(stroke, x, y, radius = ERASER_RADIUS) {
  const pts = stroke.points;
  if (!pts.length) return false;
  const reach = radius + strokeWidth(stroke) / 2;
  for (let i = 0; i < Math.max(1, pts.length - 1); i++) {
    const a = pts[i], b = pts[i + 1] || a;
    if (distToSegment(x, y, a[0], a[1], b[0], b[1]) <= reach) return true;
  }
  return false;
}

// Saved data comes from outside: keep only strokes that can be drawn, in canonical shape.
function normalise(list) {
  return (Array.isArray(list) ? list : [])
    .filter(s => s && Array.isArray(s.points) && s.points.length)
    .map(s => ({
      tool: s.tool === 'highlighter' ? 'highlighter' : 'pen',
      color: String(s.color || '#000'),
      size: +s.size > 0 ? +s.size : 3,
      points: s.points,
    }));
}

// ---------- engine ----------

// onErase() is called after an erasing gesture that removed at least one stroke.
export function createInk(svg, { scroller, onChange, onZoom, onDoubleTap, onErase } = {}) {
  let tool = 'pen', color = '#000', size = 3;
  let strokes = [];   // committed strokes; the array is replaced, never mutated
  let els = [];       // one <path> per stroke, same order
  const undoStack = [], redoStack = [];   // snapshots of `strokes`
  // Gesture in progress: draw {id, touch, at, stroke, path} or erase {id, touch, at, before, last}.
  // `at` is the pointer's last screen position; `touch` marks a finger (it may turn out to be a pinch or a palm).
  let act = null;
  const pans = new Map();   // pointers that pan: id -> {x, y, ox, oy, touch, live}; two of them also pinch-zoom
  // Fingers scroll and zoom; only a stylus or mouse draws. That is the palm rejection that matters:
  // a hand on the screen can never leave a mark. setFingerDraw(true) lets one finger draw instead
  // (two still pan and zoom), for people without a stylus.
  let fingerDraw = false;
  // Whether the stylus is touching the page, from our own down/up bookkeeping: `buttons` and
  // `pressure` on its move events are not dependable across browsers.
  let penDown = false;
  let vel = null;     // scroll velocity of a one-pointer pan in px/ms: {x, y, t}
  let glide = 0;      // rAF handle of the inertia scroll after a flick
  let lastContact = -Infinity;   // event time of the stylus last touching the page
  const fingers = new Map();   // every finger on the page, palm or not: id -> {x, y, t, solo}, to spot taps
  let lastTap = null;          // {x, y, t} of a finger tap that may become a double tap

  svg.style.touchAction = 'none';
  svg.style.cursor = CURSORS[tool];
  // Safari on iPad: with Scribble switched on, the system swallows Apple Pencil pointer events on a
  // page unless the matching touch events are cancelled. This also stops its double-tap zoom.
  for (const type of ['touchstart', 'touchmove', 'touchend']) {
    svg.addEventListener(type, e => { if (e.cancelable) e.preventDefault(); }, { passive: false });
  }

  // The strokes live in their own group, in order; the tip preview sits after it, so above them all.
  const layer = document.createElementNS(NS, 'g');
  svg.appendChild(layer);

  // Preview of the tip under a hovering stylus (Apple Pencil hover, S Pen, Surface Pen).
  const nib = document.createElementNS(NS, 'circle');
  nib.setAttribute('fill-opacity', 0.5);
  nib.style.pointerEvents = 'none';
  nib.style.display = 'none';
  svg.appendChild(nib);

  function showNib(e) {
    const pt = !penDown && tool !== 'hand' && toPoint(e);
    nib.style.display = pt ? '' : 'none';
    if (!pt) return;
    const rubber = tool === 'eraser';
    nib.setAttribute('cx', pt[0]);
    nib.setAttribute('cy', pt[1]);
    nib.setAttribute('r', rubber ? ERASER_RADIUS : Math.max(1.5, strokeWidth({ tool, size }) / 2));
    nib.setAttribute('fill', rubber ? 'none' : color);
    nib.setAttribute('stroke', rubber ? '#888' : 'none');
  }

  const getStrokes = () => strokes.slice();
  const changed = () => { if (onChange) onChange(getStrokes()); };

  function makePath(s) {
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', strokeData(s));
    if (s.points[0].length > 2) {   // pressure-sensitive: a filled outline, not a stroked line
      p.setAttribute('fill', s.color);
      return p;
    }
    p.setAttribute('fill', 'none');
    p.setAttribute('stroke', s.color);
    p.setAttribute('stroke-width', strokeWidth(s));
    p.setAttribute('stroke-linecap', 'round');
    p.setAttribute('stroke-linejoin', 'round');
    if (s.tool === 'highlighter') {
      // One path + stroke-opacity: self-overlaps do not darken.
      p.setAttribute('stroke-opacity', HIGHLIGHTER_OPACITY);
      p.style.mixBlendMode = 'multiply';
    }
    return p;
  }

  // stroke -> its <path>. Building and painting a path is the costly part, so each stroke gets one
  // element for life, and it is re-attached, not rebuilt, when the stroke comes back (undo, redo).
  const elOf = new WeakMap();
  function pathOf(s) {
    let p = elOf.get(s);
    if (!p) elOf.set(s, p = makePath(s));
    return p;
  }

  // Make the page show exactly the current strokes, in order, touching only the elements that differ.
  function render() {
    els = strokes.map(pathOf);
    const keep = new Set(els);
    for (const el of [...layer.children]) if (!keep.has(el)) el.remove();
    // What is left is in the right relative order (strokes never reorder), so only the gaps need filling.
    els.forEach((el, i) => { if (layer.children[i] !== el) layer.insertBefore(el, layer.children[i] || null); });
  }

  function commit(next, prev = strokes) {
    undoStack.push(prev);
    if (undoStack.length > MAX_HISTORY) undoStack.shift();
    redoStack.length = 0;
    strokes = next;
    changed();
  }

  // Commit whatever pen/mouse gesture is in progress. Safe to call any time.
  function finish() {
    const a = act;
    if (!a) return;
    act = null;
    if (a.path) {
      els.push(a.path);   // the live path becomes the stroke's element
      elOf.set(a.stroke, a.path);
      commit([...strokes, a.stroke]);
    } else if (strokes !== a.before) {
      commit(strokes, a.before);   // everything erased in this drag = one undo step
      if (onErase) onErase();
    }
  }

  // Pointer position in viewBox units, from where the svg really is on screen (read fresh every
  // time: zoom, scroll and viewBox change). Not getScreenCTM(): Safari's ignores a CSS transform on
  // an ancestor (WebKit bug 209220), and the app zooms the page with one, so ink landed off the tip.
  function toPoint(e) {
    const box = svg.getBoundingClientRect(), view = svg.viewBox.baseVal;
    if (!box.width || !box.height || !view.width) return null;
    return [
      round1(view.x + (e.clientX - box.left) / box.width * view.width),
      round1(view.y + (e.clientY - box.top) / box.height * view.height),
    ];
  }

  // Erase along the eraser's path from a.last to `to`. It has to stay cheap on a full page, since it
  // runs on every pointer move: only strokes whose bounding box the sweep reaches are examined, and
  // only the elements of the strokes that go are touched.
  function eraseAlong(a, to) {
    const [x0, y0] = a.last, [x1, y1] = to;
    a.last = to;
    const left = Math.min(x0, x1) - ERASER_RADIUS, right = Math.max(x0, x1) + ERASER_RADIUS;
    const top = Math.min(y0, y1) - ERASER_RADIUS, bottom = Math.max(y0, y1) + ERASER_RADIUS;
    // Sampled along the sweep, a radius apart, so a fast swipe cannot jump over a stroke.
    const steps = Math.max(1, Math.ceil(Math.hypot(x1 - x0, y1 - y0) / ERASER_RADIUS));
    const gone = new Set();
    strokes.forEach((s, i) => {
      const box = boxOf(s);
      if (box[0] > right || box[2] < left || box[1] > bottom || box[3] < top) return;
      for (let k = 1; k <= steps; k++) {
        if (hitStroke(s, x0 + (x1 - x0) * k / steps, y0 + (y1 - y0) * k / steps)) { gone.add(i); break; }
      }
    });
    if (!gone.size) return;
    for (const i of gone) els[i].remove();
    strokes = strokes.filter((_, i) => !gone.has(i));
    els = els.filter((_, i) => !gone.has(i));
  }

  // Throw away the gesture in progress without committing it.
  function discard() {
    const a = act;
    act = null;
    if (a.path) a.path.remove();
    else if (strokes !== a.before) { strokes = a.before; render(); }
  }

  // Centre of the panning pointers and, with two or more, the distance between the first two.
  function grip() {
    const pts = [...pans.values()];
    return {
      x: pts.reduce((sum, p) => sum + p.x, 0) / pts.length,
      y: pts.reduce((sum, p) => sum + p.y, 0) / pts.length,
      spread: pts.length > 1 ? Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y) : 0,
    };
  }

  // The stylus has touched the page, so touches already on it belong to the writing hand: they stop
  // scrolling and zooming for as long as they stay down, and a stroke a finger had started is dropped.
  // (A hovering stylus changes nothing: people scroll with a finger while holding it close.)
  function dropPalms() {
    for (const [id, p] of pans) if (p.touch) pans.delete(id);
    if (act && act.touch) discard();
    vel = null;
  }

  // After a flick, keep scrolling and slow down, as touch scrolling does everywhere else.
  function coast() {
    let last = 0;
    const tick = now => {
      const dt = last ? Math.min(now - last, 50) : 16;
      last = now;
      scroller.scrollBy({ left: vel.x * dt, top: vel.y * dt, behavior: 'instant' });
      const slow = 0.998 ** dt;
      vel.x *= slow;
      vel.y *= slow;
      glide = Math.hypot(vel.x, vel.y) > 0.03 ? requestAnimationFrame(tick) : 0;
    };
    glide = requestAnimationFrame(tick);
  }

  function down(e) {
    const rubber = e.button === 5;   // the eraser end of a stylus
    if (e.button !== 0 && !rubber) return;   // otherwise primary button / pen tip / finger only
    const isTouch = e.pointerType === 'touch', isPen = e.pointerType === 'pen';
    if (isTouch) {
      for (const f of fingers.values()) f.solo = false;
      fingers.set(e.pointerId, { x: e.clientX, y: e.clientY, t: e.timeStamp, solo: fingers.size === 0 });
    }
    if (isPen) {
      penDown = true;
      lastContact = e.timeStamp;
      nib.style.display = 'none';
      dropPalms();
    } else if (isTouch && (penDown || e.timeStamp - lastContact < PALM_AFTER_PEN)) {
      // Lands while the stylus is writing or the instant it lifted: a palm. It joins no gesture,
      // so its later events are ignored for as long as it stays down.
      return;
    } else if (isTouch && act && act.touch) {
      // A second finger while one is drawing: that was the start of a two-finger pan or pinch.
      pans.set(act.id, { x: act.at[0], y: act.at[1], touch: true, live: true });
      discard();
    }
    cancelAnimationFrame(glide);
    vel = null;
    if (tool === 'hand' || (isTouch && (!fingerDraw || pans.size))) {
      // `live`: has travelled PAN_SLOP from where it landed (ox, oy). A resting touch must not nudge the page.
      pans.set(e.pointerId, { x: e.clientX, y: e.clientY, ox: e.clientX, oy: e.clientY, touch: isTouch, live: !isTouch });
      if (tool === 'hand') svg.style.cursor = 'grabbing';
    } else {
      finish();   // a previous gesture whose pointerup got lost must not block this one
      const pt = toPoint(e);
      if (!pt) return;
      const base = { id: e.pointerId, touch: isTouch, at: [e.clientX, e.clientY] };
      if (tool === 'eraser' || rubber) {
        act = { ...base, before: strokes, last: pt };
        eraseAlong(act, pt);
      } else {
        // A stylus that really reports pressure (0.5 is the "no sensor" value) gets a variable-width pen line.
        if (tool === 'pen' && isPen && e.pressure > 0 && e.pressure !== 0.5) pt.push(round2(e.pressure));
        const stroke = { tool, color, size, points: [pt] };
        const path = makePath(stroke);
        layer.appendChild(path);
        act = { ...base, stroke, path };
      }
    }
    try { svg.setPointerCapture(e.pointerId); } catch { /* synthetic or already-released pointer */ }
    e.preventDefault();
  }

  function move(e) {
    if (e.pointerType === 'pen') {
      if (penDown) lastContact = e.timeStamp;
      showNib(e);
    }
    const p = pans.get(e.pointerId);
    if (p) {
      if (!p.live && Math.hypot(e.clientX - p.ox, e.clientY - p.oy) >= PAN_SLOP) p.live = true;
      const from = grip();
      p.x = e.clientX;
      p.y = e.clientY;
      // Nothing scrolls under a stroke in progress, or for a touch that has not really moved yet.
      if (!p.live || act || !scroller) return;
      const to = grip();
      if (from.spread && onZoom) onZoom(to.spread / from.spread, to.x, to.y);
      const dx = from.x - to.x, dy = from.y - to.y;
      scroller.scrollBy({ left: dx, top: dy, behavior: 'instant' });
      if (pans.size > 1) {
        vel = null;
      } else {
        const dt = vel ? e.timeStamp - vel.t : 0;
        if (!vel || dt > 0) vel = { x: dt ? (dx / dt + vel.x) / 2 : 0, y: dt ? (dy / dt + vel.y) / 2 : 0, t: e.timeStamp };
      }
      return;
    }
    if (!act || act.id !== e.pointerId) return;
    const a = act;
    a.at = [e.clientX, e.clientY];
    const coalesced = e.getCoalescedEvents ? e.getCoalescedEvents() : [];
    for (const ev of coalesced.length ? coalesced : [e]) {
      const pt = toPoint(ev);
      if (!pt) continue;
      if (!a.path) { eraseAlong(a, pt); continue; }
      const pts = a.stroke.points;
      const last = pts[pts.length - 1];
      if (Math.hypot(pt[0] - last[0], pt[1] - last[1]) < MIN_STEP) continue;
      if (last.length > 2) pt.push(round2(last[2] * PRESSURE_SMOOTH + ev.pressure * (1 - PRESSURE_SMOOTH)));
      pts.push(pt);
    }
    // ponytail: rebuilds the stroke's whole path string per move, which grows with its length;
    // build it incrementally if strokes of several thousand points ever lag.
    if (a.path) a.path.setAttribute('d', strokeData(a.stroke));
  }

  // pointerup, pointercancel and lostpointercapture all end the gesture. A cancelled stylus or mouse
  // stroke is kept; a cancelled finger stroke is dropped, because that is how the system reports a
  // touch it has decided was a palm (or the start of one of its own gestures).
  function end(e) {
    if (e.pointerType === 'pen') {
      penDown = false;
      lastContact = e.timeStamp;
    }
    const f = fingers.get(e.pointerId);
    if (f) {
      fingers.delete(e.pointerId);
      // A short, still touch by one finger is a tap; two of them close together are a double tap.
      // Not while fingers draw: there a tap is a dot.
      const tap = !fingerDraw && !penDown && f.solo && e.type === 'pointerup' && e.timeStamp - f.t < TAP_MS &&
        Math.hypot(e.clientX - f.x, e.clientY - f.y) < PAN_SLOP;
      if (tap && lastTap && e.timeStamp - lastTap.t < DOUBLE_TAP_MS &&
          Math.hypot(e.clientX - lastTap.x, e.clientY - lastTap.y) < DOUBLE_TAP_DIST) {
        lastTap = null;
        if (onDoubleTap) onDoubleTap();
      } else if (tap) {
        lastTap = { x: e.clientX, y: e.clientY, t: e.timeStamp };
      }
    }
    if (pans.delete(e.pointerId)) {
      svg.style.cursor = CURSORS[tool];
      const flick = !pans.size && vel && e.type === 'pointerup' && e.pointerType !== 'mouse' && e.timeStamp - vel.t < 60;
      if (flick) coast();
      else vel = null;
    }
    if (act && act.id === e.pointerId) {
      if (act.touch && e.type === 'pointercancel') discard();
      else finish();
    }
  }

  svg.addEventListener('pointerdown', down);
  svg.addEventListener('pointermove', move);
  svg.addEventListener('pointerleave', () => { nib.style.display = 'none'; });
  for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) svg.addEventListener(type, end);

  function step(from, to) {
    finish();
    if (!from.length) return;
    to.push(strokes);
    strokes = from.pop();
    render();
    changed();
  }

  return {
    setTool(name) {
      if (!CURSORS[name]) return;
      tool = name;
      svg.style.cursor = CURSORS[name];
    },
    setFingerDraw(on) { fingerDraw = !!on; },
    setColor(cssColor) { if (cssColor) color = String(cssColor); },
    setSize(n) { if (+n > 0) size = +n; },
    undo: () => step(undoStack, redoStack),
    redo: () => step(redoStack, undoStack),
    canUndo: () => undoStack.length > 0,
    canRedo: () => redoStack.length > 0,
    clear() {
      finish();
      if (!strokes.length) return;
      const prev = strokes;
      strokes = [];
      render();
      commit(strokes, prev);
    },
    load(list) {
      if (act && act.path) act.path.remove();   // drop any half-drawn stroke
      act = null;
      strokes = normalise(list);
      undoStack.length = redoStack.length = 0;
      render();
    },
    getStrokes,
  };
}
