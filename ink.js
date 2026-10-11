// ink.js — freehand annotation layer for EngiNote. Plain ES module.
// The flow pen's shape comes from perfect-freehand, kept beside this file.
import { getStroke } from './perfect-freehand.js';

const NS = 'http://www.w3.org/2000/svg';
const HIGHLIGHTER_SCALE = 5;      // highlighter width = size * this
const HIGHLIGHTER_OPACITY = 0.35;
const ERASER_RADIUS = 8;          // page px, on top of half the stroke's width; the default, see setEraserSize()
// A pointer's positions are never a clean line: the hand shakes, and a device may report whole
// pixels only, which turns a slow diagonal into stairs. Zoomed in, a line drawn straight through
// them looks lumpy. So the ink follows a point that trails the tip, pulled along behind it:
const SMOOTH = 3;                 // screen px the ink trails the tip by, about; bumps shorter than a few times this are ironed out
const MIN_STEP = 2;               // screen px between the points that are kept
const MAX_HISTORY = 100;
// A glow stroke is its line drawn several times over: wide and faint underneath, then narrower and
// stronger, then the line itself with a pale core. [width factor, opacity] per halo layer, widest first.
// (A blur filter would look softer, but one per stroke is what makes a full page slow to repaint.)
const GLOW_HALO = [[5, 0.1], [3.2, 0.16], [2, 0.26]];
const GLOW_CORE = [0.35, 0.6];    // the pale line down the middle: width factor, opacity
// The tools, each with its cursor. 'pen' draws an even line; 'flow' is the pen whose line swells and
// thins as it is drawn; 'glow' is an even line with a halo.
const CURSORS = { pen: 'crosshair', flow: 'crosshair', glow: 'crosshair', highlighter: 'crosshair', eraser: 'cell', hand: 'grab', lasso: 'crosshair' };
// How perfect-freehand shapes a flow stroke. thinning: how much pressure changes the width (at
// pressure 0.5 the line is exactly `size` wide). streamline: how far the line lags the hand to
// take the shake out. Chosen by eye in a browser: tune on the real device.
const FLOW = { thinning: 0.6, smoothing: 0.6, streamline: 0.6 };

// Stylus and palm tuning. Chosen without the hardware to hand: calibrate on the real device.
const PRESSURE_SMOOTH = 0.6;      // weight of the previous sample when smoothing raw pressure
const PALM_AFTER_PEN = 300;       // ms after the stylus leaves the page: a touch landing this soon is taken for the palm
const PAN_SLOP = 8;               // screen px a finger must travel before it starts to scroll or zoom
const TAP_MS = 250;               // longest a finger may stay down and still count as a tap
const DOUBLE_TAP_MS = 400;        // longest gap between the two taps of a double tap
const DOUBLE_TAP_DIST = 40;       // screen px the two taps may be apart

const round2 = n => Math.round(n * 100) / 100;

// ---------- pure geometry (no DOM) ----------

/** Rendered width of a stroke in page pixels (for a flow stroke: its width at pressure 0.5). */
export function strokeWidth(stroke) {
  return stroke.tool === 'highlighter' ? stroke.size * HIGHLIGHTER_SCALE : stroke.size;
}

// A flow stroke is drawn as one filled outline, not a stroked line. Besides 'flow' strokes these
// are the strokes of the earlier "crayon": saved as 'pen', with a pressure on every point.
const isFlow = stroke => stroke.tool === 'flow' || stroke.points[0].length > 2;

/** How see-through a stroke is drawn, 0..1. The highlighter's default is for strokes saved before pens had their own. */
export const opacityOf = stroke => stroke.opacity ?? (stroke.tool === 'highlighter' ? HIGHLIGHTER_OPACITY : 1);

// Path data for the outline of a flow stroke. Its points are [x, y] or, from a stylus that reports
// it, [x, y, pressure]; without pressure the width follows the speed of the hand instead.
// `done` is false while the stroke is still being drawn (its end then trails the pointer a little).
function flowData(stroke, done) {
  const edge = getStroke(stroke.points, { ...FLOW, size: stroke.size, simulatePressure: stroke.points[0].length < 3, last: done });
  const n = edge.length;
  if (n < 4) return '';
  // Curves through the midpoints of the outline's points, as the library's notes suggest.
  const half = (a, b) => `${round2((a[0] + b[0]) / 2)} ${round2((a[1] + b[1]) / 2)}`;
  let d = `M${round2(edge[0][0])} ${round2(edge[0][1])}Q${round2(edge[1][0])} ${round2(edge[1][1])} ${half(edge[1], edge[2])}T`;
  for (let i = 2; i < n - 1; i++) d += half(edge[i], edge[i + 1]) + ' ';
  return d + 'Z';
}

/** Path data for any stroke: an outline to fill for a flow stroke, a line to stroke otherwise. */
export function strokeData(stroke, done = true) {
  return isFlow(stroke) ? flowData(stroke, done) : pathData(stroke.points);
}

const boxes = new WeakMap();
/** [minX, minY, maxX, maxY] of a stroke's ink. Cached: a stroke is never changed once it is committed. */
export function boxOf(stroke) {
  let box = boxes.get(stroke);
  if (!box) {
    // A flow stroke at full pressure is 1 + thinning times its size across: allow the whole size either side.
    const half = isFlow(stroke) ? stroke.size : strokeWidth(stroke) / 2;
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
      tool: s.tool === 'highlighter' || s.tool === 'glow' || s.tool === 'flow' ? s.tool : 'pen',
      color: String(s.color || '#000'),
      size: +s.size > 0 ? +s.size : 3,
      ...(s.opacity > 0 && s.opacity <= 1 ? { opacity: +s.opacity } : {}),
      points: s.points,
    }));
}

// ---------- engine ----------

// onZoom(factor, x, y, hold) is called as two fingers move: zoom by `factor` and keep page point
// `hold` (viewBox units) at screen position (x, y). onZoomEnd() follows once, when that gesture is over.
// onErase() is called after an erasing gesture that removed at least one stroke.
// `surface` is the element whose pointer events are handled: the svg itself, or something around
// it (the app passes the whole note window, so fingers can pan and pinch on the margin too).
// Strokes and erasing still only start on the svg.
export function createInk(svg, { scroller, surface = svg, onChange, onZoom, onZoomEnd, onDoubleTap, onErase } = {}) {
  let tool = 'pen', color = '#000', size = 3, opacity = 1;
  // Committed strokes; the array is replaced, never mutated. A stroke's `tool` is how it is drawn:
  // 'pen', 'flow', 'highlighter' or 'glow'.
  let strokes = [];
  let els = [];       // one element per stroke, same order
  const undoStack = [], redoStack = [];   // snapshots of `strokes`
  // Gesture in progress: draw {id, touch, at, stroke, path, tip, soft, kept} or erase {id, touch, at, before, last}.
  // `at` is the pointer's last screen position; `touch` marks a finger (it may turn out to be a pinch or a palm).
  // While drawing, in screen px: `tip` is the last position reported, `soft` the smoothed point trailing
  // it (see SMOOTH), `kept` the last one that became a point of the stroke.
  let act = null;
  // The lasso is a tool the engine only carries the pointer for. Which pointer may use it is decided
  // here exactly as for a pen (so a palm can no more move ink than leave a mark); what its gesture
  // does is lasso.js's business. `lasso` is its handler (see setLasso); its gesture is {id, touch, at, own}.
  let lasso = null;
  const pans = new Map();   // pointers that pan: id -> {x, y, ox, oy, touch, live}; two of them also pinch-zoom
  let grab = null;          // the page point a two-finger gesture took hold of; it stays under the fingers' centre
  let zooming = false;      // onZoom has been called in the current two-finger gesture, so onZoomEnd is owed
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

  surface.style.touchAction = svg.style.touchAction = 'none';
  svg.style.cursor = CURSORS[tool];
  // Safari on iPad: with Scribble switched on, the system swallows Apple Pencil pointer events on a
  // page unless the matching touch events are cancelled. This also stops its double-tap zoom.
  for (const type of ['touchstart', 'touchmove', 'touchend']) {
    surface.addEventListener(type, e => { if (e.cancelable) e.preventDefault(); }, { passive: false });
  }

  // The strokes live in their own group, in order; the tip preview sits after it, so above them all.
  const layer = document.createElementNS(NS, 'g');
  svg.appendChild(layer);

  // The tip's circle. For a drawing tool it is a preview under a hovering stylus (Apple Pencil hover,
  // S Pen, Surface Pen): the size and colour the line will have. For the eraser it is the area that
  // erases: shown under a hovering stylus or mouse, and for as long as the eraser is being dragged.
  const nib = document.createElementNS(NS, 'circle');
  nib.setAttribute('stroke-width', 1.5);
  nib.setAttribute('vector-effect', 'non-scaling-stroke');   // the ring stays 1.5px on screen at any zoom
  nib.style.pointerEvents = 'none';
  nib.style.display = 'none';
  svg.appendChild(nib);
  let eraserRadius = ERASER_RADIUS;

  function showNib(e) {
    // The lasso has no tip to preview. (The eraser end of a stylus still erases with it, and shows its ring.)
    if (tool === 'lasso' && !(act && act.before)) { nib.style.display = 'none'; return; }
    const erasing = act && !act.path;
    if (erasing && act.id !== e.pointerId) return;   // while erasing, only the eraser's own pointer moves the ring
    const hovering = !erasing && tool !== 'hand' && svg.contains(e.target) &&
      (e.pointerType === 'pen' ? !penDown : e.pointerType === 'mouse' && tool === 'eraser' && e.buttons === 0);
    if (!erasing && !hovering && e.pointerType === 'touch') return;   // a finger elsewhere leaves a stylus's preview alone
    const pt = (erasing || hovering) && toPoint(e);
    nib.style.display = pt ? '' : 'none';
    if (!pt) return;
    const rubber = erasing || tool === 'eraser';
    nib.setAttribute('cx', pt[0]);
    nib.setAttribute('cy', pt[1]);
    nib.setAttribute('r', rubber ? eraserRadius : Math.max(1.5, strokeWidth({ tool, size }) / 2));
    nib.setAttribute('fill', rubber ? '#888' : color);
    nib.setAttribute('fill-opacity', rubber ? 0.15 : 0.5 * opacity);
    nib.setAttribute('stroke', rubber ? '#888' : 'none');
  }

  const getStrokes = () => strokes.slice();
  const changed = () => { if (onChange) onChange(getStrokes()); };

  // A round-ended line along path data `d`.
  function line(d, colour, width, opacity = 1) {
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', d);
    p.setAttribute('fill', 'none');
    p.setAttribute('stroke', colour);
    p.setAttribute('stroke-width', width);
    p.setAttribute('stroke-linecap', 'round');
    p.setAttribute('stroke-linejoin', 'round');
    if (opacity < 1) p.setAttribute('stroke-opacity', opacity);
    return p;
  }

  // The element that draws a stroke: a <path>, or for a glow stroke a <g> of them sharing one path data.
  // `done`: the stroke is complete (false for the one being drawn).
  function makeEl(s, done = true) {
    const d = strokeData(s, done);
    let el;
    if (isFlow(s)) {
      el = document.createElementNS(NS, 'path');
      el.setAttribute('d', d);
      el.setAttribute('fill', s.color);
    } else if (s.tool === 'glow') {
      el = document.createElementNS(NS, 'g');
      for (const [factor, faint] of GLOW_HALO) el.appendChild(line(d, s.color, s.size * factor, faint));
      el.appendChild(line(d, s.color, s.size));
      el.appendChild(line(d, '#fff', s.size * GLOW_CORE[0], GLOW_CORE[1]));
    } else {
      el = line(d, s.color, strokeWidth(s));
      if (s.tool === 'highlighter') el.style.mixBlendMode = 'multiply';
    }
    // On the whole element, so a stroke does not darken where it crosses itself.
    if (opacityOf(s) < 1) el.setAttribute('opacity', opacityOf(s));
    return el;
  }

  // New path data for a stroke's element, while the stroke is being drawn.
  function setData(el, d) {
    for (const p of el.tagName === 'g' ? el.children : [el]) p.setAttribute('d', d);
  }

  // stroke -> its element. Building and painting one is the costly part, so each stroke gets one
  // for life, and it is re-attached, not rebuilt, when the stroke comes back (undo, redo).
  const elOf = new WeakMap();
  function pathOf(s) {
    let p = elOf.get(s);
    if (!p) elOf.set(s, p = makeEl(s));
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

  // Add the tip's own position to the stroke being drawn, as its last point, unless it is there already.
  function toTip(a) {
    const pts = a.stroke.points, last = pts[pts.length - 1];
    const pt = toPoint({ clientX: a.tip[0], clientY: a.tip[1] });
    if (!pt || (pt[0] === last[0] && pt[1] === last[1])) return false;
    if (last.length > 2) pt.push(last[2]);
    pts.push(pt);
    return true;
  }

  // Commit whatever pen/mouse gesture is in progress. Safe to call any time.
  function finish() {
    const a = act;
    if (!a) return;
    act = null;
    if (a.own) return lasso.up();
    if (a.path) {
      toTip(a);   // the line ends where the tip left the page, not where the trailing point had got to
      setData(a.path, strokeData(a.stroke));   // its finished shape
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
      round2(view.x + (e.clientX - box.left) / box.width * view.width),
      round2(view.y + (e.clientY - box.top) / box.height * view.height),
    ];
  }

  // Erase along the eraser's path from a.last to `to`. It has to stay cheap on a full page, since it
  // runs on every pointer move: only strokes whose bounding box the sweep reaches are examined, and
  // only the elements of the strokes that go are touched.
  function eraseAlong(a, to) {
    const [x0, y0] = a.last, [x1, y1] = to;
    a.last = to;
    const left = Math.min(x0, x1) - eraserRadius, right = Math.max(x0, x1) + eraserRadius;
    const top = Math.min(y0, y1) - eraserRadius, bottom = Math.max(y0, y1) + eraserRadius;
    // Sampled along the sweep, a radius apart, so a fast swipe cannot jump over a stroke.
    const steps = Math.max(1, Math.ceil(Math.hypot(x1 - x0, y1 - y0) / eraserRadius));
    const gone = new Set();
    strokes.forEach((s, i) => {
      const box = boxOf(s);
      if (box[0] > right || box[2] < left || box[1] > bottom || box[3] < top) return;
      for (let k = 1; k <= steps; k++) {
        if (hitStroke(s, x0 + (x1 - x0) * k / steps, y0 + (y1 - y0) * k / steps, eraserRadius)) { gone.add(i); break; }
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
    if (a.own) return lasso.cancel();
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
    endZoom();
    if (act && act.touch) discard();
    vel = null;
  }

  // Tell the app the two-finger gesture is over: once, however it ended.
  function endZoom() {
    if (!zooming) return;
    zooming = false;
    if (onZoomEnd) onZoomEnd();
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
    } else if (tool === 'lasso' && lasso && !rubber) {
      // Anywhere in the window, the margin included: a loop round ink at the sheet's edge starts off it.
      finish();
      const pt = toPoint(e);
      if (!pt) return;
      act = { id: e.pointerId, touch: isTouch, at: [e.clientX, e.clientY], own: true };
      lasso.down(pt);
    } else {
      if (!svg.contains(e.target)) return;   // ink starts on the sheet, not on the margin around it
      finish();   // a previous gesture whose pointerup got lost must not block this one
      const pt = toPoint(e);
      if (!pt) return;
      const base = { id: e.pointerId, touch: isTouch, at: [e.clientX, e.clientY] };
      if (tool === 'eraser' || rubber) {
        act = { ...base, before: strokes, last: pt };
        eraseAlong(act, pt);
      } else {
        // The flow pen follows pressure, when the stylus really reports it (0.5 is the "no sensor"
        // value): its points then carry it. Otherwise its width follows the speed of the hand.
        if (tool === 'flow' && isPen && e.pressure > 0 && e.pressure !== 0.5) pt.push(round2(e.pressure));
        const stroke = { tool, color, size, points: [pt] };
        // Kept on the stroke only where it says something, so most strokes stay as small as before.
        if (opacity < 1 || tool === 'highlighter') stroke.opacity = opacity;
        const path = makeEl(stroke, false);
        layer.appendChild(path);
        act = { ...base, stroke, path, tip: base.at, soft: base.at, kept: base.at };
      }
    }
    showNib(e);   // the eraser's ring appears where it lands; a drawing tool's preview goes
    try { surface.setPointerCapture(e.pointerId); } catch { /* synthetic or already-released pointer */ }
    e.preventDefault();
  }

  function move(e) {
    if (e.pointerType === 'pen' && penDown) lastContact = e.timeStamp;
    showNib(e);
    const p = pans.get(e.pointerId);
    if (p) {
      if (!p.live && Math.hypot(e.clientX - p.ox, e.clientY - p.oy) >= PAN_SLOP) p.live = true;
      const from = grip();
      p.x = e.clientX;
      p.y = e.clientY;
      // Nothing scrolls under a stroke in progress, or for a touch that has not really moved yet.
      if (!p.live || act || !scroller) return;
      const to = grip();
      if (pans.size > 1) {
        // Two fingers pan and zoom in one step: the app zooms by the change in their spread and puts
        // the grabbed page point back under their centre. That point is named once, as the gesture
        // really starts (the first move past the slop), not re-read on every move: re-reading is
        // what let the page creep as rounding errors added up.
        if (onZoom && from.spread) {
          if (!zooming) grab = toPoint({ clientX: from.x, clientY: from.y });
          zooming = true;
          onZoom(to.spread / from.spread, to.x, to.y, grab);
        }
        vel = null;
        return;
      }
      const dx = from.x - to.x, dy = from.y - to.y;
      scroller.scrollBy({ left: dx, top: dy, behavior: 'instant' });
      const dt = vel ? e.timeStamp - vel.t : 0;
      if (!vel || dt > 0) vel = { x: dt ? (dx / dt + vel.x) / 2 : 0, y: dt ? (dy / dt + vel.y) / 2 : 0, t: e.timeStamp };
      return;
    }
    if (!act || act.id !== e.pointerId) return;
    const a = act;
    a.at = [e.clientX, e.clientY];
    if (a.own) {
      const pt = toPoint(e);
      if (pt) lasso.move(pt);
      return;
    }
    const coalesced = e.getCoalescedEvents ? e.getCoalescedEvents() : [];
    const pts = a.path && a.stroke.points;
    for (const ev of coalesced.length ? coalesced : [e]) {
      if (!a.path) {
        const pt = toPoint(ev);
        if (pt) eraseAlong(a, pt);
        continue;
      }
      // The smoothed point moves towards the tip by a share of the gap that depends on how far the
      // tip just travelled, not on time: so a slow line is smoothed as much as a fast one, and a
      // tip at rest pulls nothing after it.
      const moved = Math.hypot(ev.clientX - a.tip[0], ev.clientY - a.tip[1]);
      if (!moved) continue;
      const share = 1 - Math.exp(-moved / SMOOTH);
      a.tip = [ev.clientX, ev.clientY];
      a.soft = [a.soft[0] + (a.tip[0] - a.soft[0]) * share, a.soft[1] + (a.tip[1] - a.soft[1]) * share];
      if (Math.hypot(a.soft[0] - a.kept[0], a.soft[1] - a.kept[1]) < MIN_STEP) continue;
      const pt = toPoint({ clientX: a.soft[0], clientY: a.soft[1] });
      if (!pt) continue;
      a.kept = a.soft;
      const last = pts[pts.length - 1];
      if (last.length > 2) pt.push(round2(last[2] * PRESSURE_SMOOTH + ev.pressure * (1 - PRESSURE_SMOOTH)));
      pts.push(pt);
    }
    if (a.path) {
      // Drawn right up to the tip, so no gap shows between it and the trailing ink. That last
      // stretch is only for show until the smoothed point has passed over it.
      const reached = toTip(a);
      // ponytail: rebuilds the stroke's whole path string per move, which grows with its length;
      // build it incrementally if strokes of several thousand points ever lag.
      setData(a.path, strokeData(a.stroke, false));
      if (reached) pts.pop();
    }
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
    if (pans.has(e.pointerId)) {
      // A two-finger gesture ends as a whole when either finger lifts: the one still down must not
      // carry on as a scroll, or the page would slide and fling away as the hand leaves.
      const pinch = pans.size > 1;
      if (pinch) pans.clear();
      else pans.delete(e.pointerId);
      endZoom();
      svg.style.cursor = CURSORS[tool];
      const flick = !pinch && vel && e.type === 'pointerup' && e.pointerType !== 'mouse' && e.timeStamp - vel.t < 60;
      if (flick) coast();
      else vel = null;
    }
    if (act && act.id === e.pointerId) {
      if (act.touch && e.type === 'pointercancel') discard();
      else finish();
      nib.style.display = 'none';   // the eraser's ring goes with the gesture...
      showNib(e);                   // ...unless a stylus or mouse is still hovering there
    }
  }

  surface.addEventListener('pointerdown', down);
  surface.addEventListener('pointermove', move);
  // Not while erasing: capturing the pointer for a gesture counts as it leaving the svg.
  svg.addEventListener('pointerleave', () => { if (!act || act.path) nib.style.display = 'none'; });
  for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) surface.addEventListener(type, end);

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
    setEraserSize(radius) { if (+radius > 0) eraserRadius = +radius; },   // page px
    setColor(cssColor) { if (cssColor) color = String(cssColor); },
    setSize(n) { if (+n > 0) size = +n; },
    setOpacity(n) { if (+n > 0 && +n <= 1) opacity = +n; },
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
    // The lasso tool's gestures go to `handler`, as page points: down(point) when a pointer that may
    // draw lands, move(point) as it goes, then up() when it lifts, or cancel() if it turns out to
    // have been a palm or the start of a pinch.
    setLasso(handler) { lasso = handler; },
    /** The element that draws a committed stroke: to show a change to it (a move, say) before it is made. */
    elementOf: pathOf,
    // Put `next` in place of the strokes, as one undo step: for a change made to them from outside.
    // Strokes are never altered: a changed stroke is a new object in `next`, the others are the same ones.
    replace(next) {
      finish();
      const prev = strokes;
      strokes = next.slice();
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
