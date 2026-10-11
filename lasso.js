// lasso.js — the lasso tool for EngiNote: circle some ink, then move it, resize it, recolour it or
// delete it. Plain ES module. ink.js carries the pointer (which pointer may use a tool, palm
// rejection) and keeps the strokes; this file is what the lasso does with them.
import { boxOf, pathData } from './ink.js';

const NS = 'http://www.w3.org/2000/svg';
const GRIP = 18;        // screen px around a corner that take hold of its handle: a 36px target
const PAD = 6;          // screen px between the ink and the box drawn round it
const BAR_GAP = 14;     // screen px between that box and the bar of colours
const MIN_SCALE = 0.1;  // one resize makes the selection no smaller than this
const round2 = n => Math.round(n * 100) / 100;
const clamp = (n, low, high) => Math.min(high, Math.max(low, n));

// ---------- pure geometry (no DOM) ----------

/** True if (x, y) is inside the closed loop [[x, y], ...]. Where a loop crosses itself, the even-odd rule decides. */
export function inLoop(loop, x, y) {
  let inside = false;
  for (let i = 0, j = loop.length - 1; i < loop.length; j = i++) {
    const [ax, ay] = loop[i], [bx, by] = loop[j];
    if ((ay > y) !== (by > y) && x < ax + (y - ay) * (bx - ax) / (by - ay)) inside = !inside;
  }
  return inside;
}

/** The strokes a loop takes: those with most of their points inside it. */
export function pick(strokes, loop) {
  if (loop.length < 3) return [];
  let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
  for (const [x, y] of loop) {
    left = Math.min(left, x); right = Math.max(right, x);
    top = Math.min(top, y); bottom = Math.max(bottom, y);
  }
  return strokes.filter(s => {
    const box = boxOf(s);   // most strokes on a full page are nowhere near the loop
    if (box[0] > right || box[2] < left || box[1] > bottom || box[3] < top) return false;
    let n = 0;
    for (const [x, y] of s.points) if (inLoop(loop, x, y)) n++;
    return n * 2 > s.points.length;
  });
}

/** A copy of a stroke scaled by k and then moved by (tx, ty): where it is and how thick it is, together. */
export function reshape(stroke, k, tx, ty) {
  return {
    ...stroke,
    size: k === 1 ? stroke.size : Math.max(0.1, round2(stroke.size * k)),
    points: stroke.points.map(([x, y, ...pressure]) => [round2(x * k + tx), round2(y * k + ty), ...pressure]),
  };
}

// ---------- the tool ----------

// `svg` is the ink's own svg and `ink` its engine. `bar` is the element holding the colour buttons
// ([data-color]) and the delete button; it is shown and placed here, by `left` and `top` inside its
// offset parent. room() gives the part of the screen the bar may sit in: [left, top, right, bottom].
export function createLasso(svg, ink, bar, room) {
  let chosen = [];   // the selected strokes, in the order they are drawn
  let box = null;    // [left, top, right, bottom] of their ink in page px, or null with nothing selected
  let shown = null;  // the same as it is drawn right now: mid-gesture, where the selection has been taken to
  // Gesture in progress. A loop being drawn: {loop: [points]}. A move or a resize of the selection:
  // {k, tx, ty}, how it is shown changed so far, with {from} (where a move took hold) or
  // {a, c, off} (a resize: the corner that stays, the corner held, and how far from it the grip was).
  let g = null;
  let mine = false;  // the strokes are changing because the lasso is changing them
  let scale = 1;     // screen px per page px, as the box was last drawn
  let seen = 1;      // ...and as it was a frame ago
  let frame = 0;     // rAF handle of follow()

  // Drawn in the ink's svg, over the strokes: so they stay on the ink whatever the view does.
  const ui = document.createElementNS(NS, 'g');
  ui.style.pointerEvents = 'none';
  const make = tag => {
    const el = ui.appendChild(document.createElementNS(NS, tag));
    el.setAttribute('class', 'lasso');   // the look is in style.css; the sizes are set here, per zoom
    return el;
  };
  const line = make('path'), rect = make('rect'), knobs = [0, 1, 2, 3].map(() => make('circle'));
  svg.appendChild(ui);

  // Lines and handles keep their size on screen: this sets them for `now`, the screen px per page px
  // (read from where the svg really is, as ink.js reads positions, and for its reason).
  function fit(now = svg.getBoundingClientRect().width / svg.viewBox.baseVal.width || 1) {
    scale = seen = now;
    for (const el of [line, rect, ...knobs]) el.setAttribute('stroke-width', 1.5 / scale);
    for (const el of [line, rect]) el.setAttribute('stroke-dasharray', `${6 / scale} ${5 / scale}`);
    for (const knob of knobs) knob.setAttribute('r', 7 / scale);
  }
  // Corner i of a box: 0 top left, 1 top right, 2 bottom left, 3 bottom right. So 3 - i is the opposite one.
  const corner = (b, i) => [b[i % 2 ? 2 : 0], b[i < 2 ? 1 : 3]];
  const outer = (b, by = PAD / scale) => [b[0] - by, b[1] - by, b[2] + by, b[3] + by];

  // Draw the box and its handles round `b` (page px).
  function draw(b = shown) {
    shown = b;
    const o = outer(b);
    rect.setAttribute('x', o[0]);
    rect.setAttribute('y', o[1]);
    rect.setAttribute('width', o[2] - o[0]);
    rect.setAttribute('height', o[3] - o[1]);
    knobs.forEach((knob, i) => {
      knob.setAttribute('cx', corner(o, i)[0]);
      knob.setAttribute('cy', corner(o, i)[1]);
    });
  }

  // Put the bar by the box: above it, or below when there is no room above, or over its top when it
  // fills the window. Always inside room().
  function placeBar(page) {
    const home = bar.offsetParent?.getBoundingClientRect();
    if (!home) return;   // the editor is not on screen
    const o = outer(shown, PAD / seen), [left, top, right, bottom] = room();
    const w = bar.offsetWidth, h = bar.offsetHeight;
    const x = page.left + (o[0] + o[2]) / 2 * seen - w / 2;
    let y = page.top + o[1] * seen - BAR_GAP - h;
    if (y < top + 8) y = page.top + o[3] * seen + BAR_GAP;
    if (y > bottom - h - 8) y = top + 8;
    const at = [`${Math.round(clamp(x, left + 8, right - w - 8) - home.left)}px`, `${Math.round(y - home.top)}px`];
    if (bar.style.left !== at[0]) bar.style.left = at[0];
    if (bar.style.top !== at[1]) bar.style.top = at[1];
  }

  // While something is selected, every frame: keep the bar by the box wherever the view takes it (a
  // pan, a pinch, a glide: this file is told of none of them), and redraw the box's lines for a new
  // zoom once it has settled. Not during a pinch: that would redraw the sheet on every frame of it.
  // ponytail: reads the svg's place each frame while a selection is up. If that ever shows in a
  // profile, have app.js call in from place() and pinchMove() instead.
  function follow() {
    cancelAnimationFrame(frame);
    if (!box) return;
    frame = requestAnimationFrame(follow);
    const page = svg.getBoundingClientRect(), now = page.width / svg.viewBox.baseVal.width;
    if (!now) return;
    if (now === seen && now !== scale) {
      fit(now);
      draw();
    }
    seen = now;
    placeBar(page);
  }

  // Make `list` the selection (none: an empty list).
  function select(list) {
    chosen = list;
    box = null;
    for (const s of list) {
      const b = boxOf(s);
      box = box ? [Math.min(box[0], b[0]), Math.min(box[1], b[1]), Math.max(box[2], b[2]), Math.max(box[3], b[3])] : b.slice();
    }
    rect.style.display = box ? '' : 'none';
    for (const knob of knobs) knob.style.display = box ? '' : 'none';
    bar.hidden = !box;
    if (box) {
      fit();
      draw(box);
    }
    follow();
  }

  // Show the selected strokes as they would be, scaled by k then moved by (tx, ty); nothing is changed yet.
  function preview(k, tx, ty) {
    const t = k === 1 && !tx && !ty ? null : `matrix(${k} 0 0 ${k} ${tx} ${ty})`;
    for (const s of chosen) t ? ink.elementOf(s).setAttribute('transform', t) : ink.elementOf(s).removeAttribute('transform');
    draw([box[0] * k + tx, box[1] * k + ty, box[2] * k + tx, box[3] * k + ty]);
  }

  // Put a changed copy in place of every selected stroke (or nothing, where `change` gives none):
  // one undo step. The copies are then the selection.
  function replace(change) {
    const made = new Map(chosen.map(s => [s, change(s)]));
    mine = true;
    ink.replace(ink.getStrokes().map(s => (made.has(s) ? made.get(s) : s)).filter(Boolean));
    mine = false;
    select([...made.values()].filter(Boolean));
  }

  // Drop the gesture in progress, leaving the ink as it was.
  function cancel() {
    if (g && !g.loop && box) preview(1, 0, 0);
    line.removeAttribute('d');
    g = null;
  }

  ink.setLasso({
    down(pt) {
      if (box) {
        const o = outer(box), grip = GRIP / scale;
        const held = [0, 1, 2, 3].find(i => Math.hypot(pt[0] - corner(o, i)[0], pt[1] - corner(o, i)[1]) <= grip);
        if (held !== undefined) {
          const c = corner(box, held);
          g = { k: 1, tx: 0, ty: 0, a: corner(box, 3 - held), c, off: [pt[0] - c[0], pt[1] - c[1]] };
          return;
        }
        // Inside the box moves it. A box round one thin line is still a 36px target.
        const mx = Math.max(o[2] - box[2], grip - (box[2] - box[0]) / 2), my = Math.max(o[3] - box[3], grip - (box[3] - box[1]) / 2);
        if (pt[0] >= box[0] - mx && pt[0] <= box[2] + mx && pt[1] >= box[1] - my && pt[1] <= box[3] + my) {
          g = { k: 1, tx: 0, ty: 0, from: pt };
          return;
        }
      }
      // Anywhere else starts a new loop, in place of the selection (so a tap out there just lets go of it).
      select([]);
      fit();
      g = { loop: [pt] };
    },
    move(pt) {
      if (!g) return;
      if (g.loop) {
        g.loop.push(pt);
        line.setAttribute('d', pathData(g.loop));
        return;
      }
      // The selection stays on the sheet: off it, it could be neither seen nor taken hold of again.
      // (Ink that already hangs over the edge may stay where it is.)
      const sheet = svg.viewBox.baseVal;
      if (g.a) {
        // A resize: how far along the box's diagonal the held corner has been taken, from the corner that stays.
        const [ax, ay] = g.a, dx = g.c[0] - ax, dy = g.c[1] - ay;
        const k = ((pt[0] - g.off[0] - ax) * dx + (pt[1] - g.off[1] - ay) * dy) / (dx * dx + dy * dy);
        const most = Math.min(((dx > 0 ? sheet.width : 0) - ax) / dx, ((dy > 0 ? sheet.height : 0) - ay) / dy);
        g.k = clamp(k, MIN_SCALE, Math.max(1, most));
        g.tx = ax * (1 - g.k);
        g.ty = ay * (1 - g.k);
      } else {
        g.tx = round2(clamp(pt[0] - g.from[0], Math.min(0, -box[0]), Math.max(0, sheet.width - box[2])));
        g.ty = round2(clamp(pt[1] - g.from[1], Math.min(0, -box[1]), Math.max(0, sheet.height - box[3])));
      }
      preview(g.k, g.tx, g.ty);
    },
    up() {
      const done = g;
      g = null;
      if (!done) return;
      if (done.loop) {
        line.removeAttribute('d');
        select(pick(ink.getStrokes(), done.loop));
        return;
      }
      preview(1, 0, 0);   // the elements shown moved belong to the old strokes, which undo brings back as they were
      if (done.k !== 1 || done.tx || done.ty) replace(s => reshape(s, done.k, done.tx, done.ty));
    },
    cancel,
  });

  bar.addEventListener('click', e => {
    const button = e.target.closest('button');
    if (!button || !box) return;
    const color = button.dataset.color;
    if (!color) replace(() => null);   // the only other button: delete
    else if (chosen.some(s => s.color !== color)) replace(s => ({ ...s, color }));
  });

  // Let go of the selection, and of any gesture in progress.
  function clear() {
    cancel();
    select([]);
  }

  select([]);
  return {
    clear,
    /** For the engine's onChange: strokes changed by anything but the lasso (undo, redo, the eraser end of a stylus) are no longer its selection. */
    changed() { if (!mine) clear(); },
  };
}
