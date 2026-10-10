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
const PALM_AFTER_PEN = 600;       // ms after the stylus last touched the page: a new touch is taken for the palm
const PALM_AFTER_HOVER = 150;     // ms after the stylus last moved just above the page: same
const PAN_SLOP = 8;               // screen px a finger must travel before it starts to scroll or zoom

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

// A pressure stroke has points [x, y, pressure] and is drawn as a filled shape: a disc at every point
// and a quad joining neighbours. Every piece winds the same way, so the default nonzero fill unions
// them without holes.
// ponytail: straight joins between samples; if fast curves look faceted on a 60 Hz stylus,
// subdivide each step along the same midpoint curve pathData() uses.
function disc([x, y, p], size) {
  const r = round2(widthAt(size, p) / 2);
  return `M${round2(x - r)} ${y}a${r} ${r} 0 1 0 ${round2(2 * r)} 0a${r} ${r} 0 1 0 ${round2(-2 * r)} 0`;
}

/** Path data that extends a pressure stroke from point a to point b. */
export function outlineStep(a, b, size) {
  const dx = b[0] - a[0], dy = b[1] - a[1], len = Math.hypot(dx, dy);
  if (!len) return disc(b, size);
  const nx = -dy / len, ny = dx / len;
  const corner = (p, side) => {
    const r = side * widthAt(size, p[2]) / 2;
    return `${round2(p[0] + nx * r)} ${round2(p[1] + ny * r)}`;
  };
  return `M${corner(a, 1)}L${corner(b, 1)}L${corner(b, -1)}L${corner(a, -1)}Z${disc(b, size)}`;
}

/** Path data for a whole pressure stroke. */
export function outlineData(points, size) {
  let d = disc(points[0], size);
  for (let i = 1; i < points.length; i++) d += outlineStep(points[i - 1], points[i], size);
  return d;
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

export function createInk(svg, { scroller, onChange, onZoom } = {}) {
  let tool = 'pen', color = '#000', size = 3;
  let strokes = [];   // committed strokes; the array is replaced, never mutated
  let els = [];       // one <path> per stroke, same order
  const undoStack = [], redoStack = [];   // snapshots of `strokes`
  // Gesture in progress: draw {id, touch, at, stroke, path, d} or erase {id, touch, at, before, last}.
  // `at` is the pointer's last screen position; `touch` marks a finger (it may turn out to be a pinch or a palm);
  // `d` is the path data so far of a pressure stroke (null for a plain line).
  let act = null;
  const pans = new Map();   // pointers that pan: id -> [clientX, clientY]; two of them also pinch-zoom
  // Fingers draw until a stylus shows up; from then on they only pan and zoom (palm rejection).
  // ponytail: forgotten on reload and there is no manual switch; add a "draw with finger" toggle if needed.
  let penSeen = false;
  let vel = null;     // scroll velocity of a one-pointer pan in px/ms: {x, y, t}
  let glide = 0;      // rAF handle of the inertia scroll after a flick
  let lastContact = -Infinity, lastHover = -Infinity;   // event times of the stylus touching / hovering over the page

  svg.style.touchAction = 'none';
  svg.style.cursor = CURSORS[tool];

  // Preview of the tip under a hovering stylus (Apple Pencil hover, S Pen, Surface Pen).
  const nib = document.createElementNS(NS, 'circle');
  nib.setAttribute('fill-opacity', 0.5);
  nib.style.pointerEvents = 'none';
  nib.style.display = 'none';
  svg.appendChild(nib);

  function showNib(e) {
    const pt = e.buttons === 0 && tool !== 'hand' && toPoint(e);
    nib.style.display = pt ? '' : 'none';
    if (!pt) return;
    const rubber = tool === 'eraser';
    nib.setAttribute('cx', pt[0]);
    nib.setAttribute('cy', pt[1]);
    nib.setAttribute('r', rubber ? ERASER_RADIUS : Math.max(1.5, strokeWidth({ tool, size }) / 2));
    nib.setAttribute('fill', rubber ? 'none' : color);
    nib.setAttribute('stroke', rubber ? '#888' : 'none');
    if (nib.nextSibling) svg.appendChild(nib);   // keep it above every stroke
  }

  const getStrokes = () => strokes.slice();
  const changed = () => { if (onChange) onChange(getStrokes()); };

  function makePath(s) {
    const p = document.createElementNS(NS, 'path');
    if (s.points[0].length > 2) {   // pressure-sensitive: a filled outline, not a stroked line
      p.setAttribute('d', outlineData(s.points, s.size));
      p.setAttribute('fill', s.color);
      return p;
    }
    p.setAttribute('d', pathData(s.points));
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

  // ponytail: full re-render on undo/redo/load/erase; diff by stroke identity if thousands of strokes get slow.
  function render() {
    for (const el of els) el.remove();
    els = strokes.map(makePath);
    for (const el of els) svg.appendChild(el);
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
      commit([...strokes, a.stroke]);
    } else if (strokes !== a.before) {
      commit(strokes, a.before);   // everything erased in this drag = one undo step
    }
  }

  // Pointer position in viewBox units. The matrix is read fresh every time (zoom/scroll/viewBox may change).
  function toPoint(e) {
    const m = svg.getScreenCTM();
    if (!m) return null;
    const p = new DOMPoint(e.clientX, e.clientY).matrixTransform(m.inverse());
    return Number.isFinite(p.x) && Number.isFinite(p.y) ? [round1(p.x), round1(p.y)] : null;
  }

  // Erase along the eraser's path from a.last to `to`, sampled so a fast swipe cannot jump over a stroke.
  // ponytail: tests every segment of every stroke; add per-stroke bounding boxes if erasing gets slow.
  function eraseAlong(a, to) {
    const [x0, y0] = a.last, [x1, y1] = to;
    const steps = Math.max(1, Math.ceil(Math.hypot(x1 - x0, y1 - y0) / ERASER_RADIUS));
    let kept = strokes;
    for (let i = 1; i <= steps; i++) {
      const x = x0 + (x1 - x0) * i / steps, y = y0 + (y1 - y0) * i / steps;
      kept = kept.filter(s => !hitStroke(s, x, y));
    }
    a.last = to;
    if (kept.length !== strokes.length) {
      strokes = kept;
      render();
    }
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

  // The stylus is here, so touches on the page belong to the writing hand: stop them scrolling and
  // zooming, and drop a stroke a finger had started. While it only hovers (`all` false), fingers
  // that are already scrolling carry on; when it touches the page, everything goes.
  function dropPalms(all) {
    for (const [id, p] of pans) if (p.touch && (all || !p.live)) pans.delete(id);
    if (act && act.touch) discard();
    if (all) vel = null;
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
    if (isPen) {
      penSeen = true;
      lastContact = e.timeStamp;
      nib.style.display = 'none';
      dropPalms(true);
    } else if (isTouch && penSeen && ((act && !act.touch) ||
        e.timeStamp - lastContact < PALM_AFTER_PEN || e.timeStamp - lastHover < PALM_AFTER_HOVER)) {
      // Lands while the stylus is writing or was here a moment ago: a palm. It joins no gesture,
      // so its later events are ignored for as long as it stays down.
      return;
    } else if (isTouch && act && act.touch) {
      // A second finger while one is drawing: that was the start of a two-finger pan or pinch.
      pans.set(act.id, { x: act.at[0], y: act.at[1], touch: true, live: true });
      discard();
    }
    cancelAnimationFrame(glide);
    vel = null;
    if (tool === 'hand' || (isTouch && (penSeen || pans.size))) {
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
        svg.appendChild(path);
        act = { ...base, stroke, path, d: pt.length > 2 ? path.getAttribute('d') : null };
      }
    }
    try { svg.setPointerCapture(e.pointerId); } catch { /* synthetic or already-released pointer */ }
    e.preventDefault();
  }

  function move(e) {
    if (e.pointerType === 'pen') {
      penSeen = true;   // hovering counts, so a palm that lands before the tip is already a palm
      if (e.buttons === 0) {
        lastHover = e.timeStamp;
        dropPalms(false);
      } else {
        lastContact = e.timeStamp;
      }
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
      if (a.d) {
        pt.push(round2(last[2] * PRESSURE_SMOOTH + ev.pressure * (1 - PRESSURE_SMOOTH)));
        a.d += outlineStep(last, pt, a.stroke.size);
      }
      pts.push(pt);
    }
    // ponytail: a plain line rebuilds its whole path string per move; append incrementally (as the
    // pressure outline does) if very long strokes lag.
    if (a.path) a.path.setAttribute('d', a.d || pathData(a.stroke.points));
  }

  // pointerup, pointercancel and lostpointercapture all end the gesture. A cancelled stylus or mouse
  // stroke is kept; a cancelled finger stroke is dropped, because that is how the system reports a
  // touch it has decided was a palm (or the start of one of its own gestures).
  function end(e) {
    if (e.pointerType === 'pen') lastContact = e.timeStamp;
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
