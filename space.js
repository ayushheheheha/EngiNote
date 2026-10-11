// space.js — "Add space": more room in a note that is already written on. Plain ES module.
//
// It is a mode, switched by a toolbar button. While it is on, the places where room can be made
// are marked on the sheet, and a tap on one makes it:
//   in a paged note, a blank page between two pages or at the end (and a blank page nobody has
//   written on can be taken out again);
//   in an HTML note, a gap between two of its blocks, which can then be dragged taller or shorter,
//   or removed.
// Either way the ink below moves with what it was written on (ink.shift).
// The model, and the document a note is shown as, are in pages.js.
import { PAGE_WIDTH, GAP_MARK, kids, spacerStyle, pageTops, inkedPages, addPage, removePage } from './pages.js';

const GAP = 600;                    // page px: how tall a new gap is
const MIN_GAP = 40, MAX_GAP = 6000; // what a gap can be dragged to
const NEAR = 52;                    // screen px: two "+" closer together than this would overlap

const PLUS = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>';
const GRIP = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4v16M8 8l4-4 4 4M8 16l4 4 4-4"/></svg>';

// ---------- the blocks of an HTML note ----------

// The children of `el` that are blocks of the page: in the flow, and taking up room.
function solid(el) {
  const view = el.ownerDocument.defaultView;
  return kids(el).filter(c => {
    const style = view.getComputedStyle(c), box = c.getBoundingClientRect();
    return box.width > 0 && box.height > 0 && !/^(inline|contents|none)/.test(style.display) && !/absolute|fixed/.test(style.position);
  });
}

// The note's top-level blocks: <body>'s children, or, while there is only one (a wrapper), that one's.
function blocksOf(doc) {
  let list = solid(doc.body);
  for (let inner; list.length === 1 && (inner = solid(list[0])).length;) list = inner;
  return list;
}

// From <body> to `el`, as child indexes (see pages.js).
function pathTo(el) {
  const path = [];
  for (const body = el.ownerDocument.body; el !== body; el = el.parentElement) path.unshift(kids(el.parentElement).indexOf(el));
  return path;
}

// ---------- the mode ----------

// `button` switches it. `mover` is the element the sheet is in, moved but not scaled by the view;
// `frame` shows the note; `ink` is the ink engine; note() is the note that is open; resize() has the
// app measure the note again after it grew or shrank.
export function createSpace({ button, mover, frame, ink, note, resize }) {
  let on = false;
  // The gaps of the open HTML note, as they stand in the frame: { gap, el, after, next }. `gap` is
  // the record in note.gaps, `el` its spacer, `after` the block it comes after, `next` the block
  // after it (none at the end of the note).
  let open = [];

  // The marks lie over the sheet, in #mover: they move with it, but are not scaled with it, so a
  // button is the same size under the finger at any zoom. Only the buttons take touches, and those
  // stop here: the window around them (ink.js) would take them for the start of a stroke or a pan,
  // and would cancel the touch a tap is made of.
  const layer = document.createElement('div');
  layer.id = 'space';
  mover.append(layer);
  for (const type of ['pointerdown', 'touchstart', 'touchmove', 'touchend']) layer.addEventListener(type, e => e.stopPropagation());

  // One thing on the layer. `at`: where, in screen px from the sides named.
  function put(parent, tag, cls, at = {}, label) {
    const el = document.createElement(tag);
    el.className = cls;
    for (const side in at) el.style[side] = at[side] + 'px';
    if (label) {
      el.type = 'button';
      el.title = label;
      el.setAttribute('aria-label', label);
    }
    parent.append(el);
    return el;
  }

  // Where a gap is on the page, [top, bottom]: the stretch that was not there before it.
  function zone(g) {
    const above = g.after.getBoundingClientRect().bottom;
    const top = g.next ? above + (g.next.getBoundingClientRect().top - above - g.gap.height) / 2 : above;
    return [top, top + g.gap.height];
  }

  // Draw the marks for the note as it now is. Called whenever the note, its ink or the zoom changes.
  function refresh() {
    layer.replaceChildren();
    const doc = note(), z = parseFloat(mover.style.width) / PAGE_WIDTH;
    if (!on || !doc || !z) return;
    const foot = parseFloat(mover.style.height);
    // A line across the sheet at page height `y`, with a "+" on it.
    const plus = (y, label, run) => {
      const line = put(layer, 'div', foot - y * z < 26 ? 'space-line end' : 'space-line', { top: y * z }); // at the very foot, the "+" stays on the sheet
      const btn = put(line, 'button', 'space-add', {}, label);
      btn.innerHTML = PLUS;
      btn.onclick = run;
    };

    if (doc.pages) {
      const tops = pageTops(doc), inked = inkedPages(doc, ink.getStrokes()), n = doc.pages.length;
      for (let i = 1; i <= n; i++) plus(tops[i], i < n ? 'Add a page here' : 'Add a page at the end', () => insertPage(i));
      doc.pages.forEach((page, i) => {
        // A blank page nobody has written on can go. Not the last one while the page before it has
        // ink: a notebook keeps a blank page ahead (pages.js, needsPage), so it would be back at once.
        if (page.img || inked[i] || n < 2 || (i === n - 1 && inked[i - 1] && !doc.pages[i - 1].img)) return;
        const btn = put(layer, 'button', 'space-pill', { top: tops[i] * z + 10, right: 10 }, 'Remove this blank page');
        btn.textContent = 'Remove page';
        btn.onclick = () => dropPage(i);
      });
      return;
    }

    for (const g of open) {
      const box = put(layer, 'div', 'space-zone', { top: zone(g)[0] * z, height: g.gap.height * z });
      const remove = put(box, 'button', 'space-pill', { top: 10, right: 10 }, 'Remove this space');
      remove.textContent = 'Remove space';
      remove.onclick = () => removeGap(g);
      const grip = put(box, 'button', 'space-grip', {}, 'Drag to make this space taller or shorter');
      grip.innerHTML = GRIP;
      drag(grip, box, g, z);
    }
    // A gap can be opened only where the note divides cleanly in two: everything so far ends above
    // everything still to come. That leaves out the boundaries between things that sit side by side.
    const blocks = blocksOf(frame.contentDocument), boxes = blocks.map(b => b.getBoundingClientRect());
    const below = []; // below[i]: the highest top among the blocks from i on
    for (let i = blocks.length, top = Infinity; i >= 0; i--) below[i] = top = Math.min(top, boxes[i]?.top ?? Infinity);
    let above = -Infinity, last = -Infinity;
    blocks.forEach((block, i) => {
      const stacked = boxes[i].top >= above - 0.5; // not beside what came before it
      above = Math.max(above, boxes[i].bottom);
      if (above > below[i + 1] + 0.5 || open.some(g => g.after === block)) return;
      const end = i === blocks.length - 1;
      if (end && !stacked) return;
      const y = end ? above : (above + below[i + 1]) / 2;
      if ((y - last) * z < NEAR) return; // zoomed far out, blocks come closer than the marks are tall: zoom in for the rest
      last = y;
      plus(y, end ? 'Add space at the end' : 'Add space here', () => addGap(block, blocks[i + 1], y));
    });
  }

  // ---------- pages ----------

  function insertPage(i) {
    const doc = note(), top = pageTops(doc)[i];
    const page = addPage(doc, i, frame.contentDocument);
    ink.shift(top, page.h); // also tells the app the note changed: it is saved
    resize();
    refresh();
  }

  function dropPage(i) {
    const doc = note(), bottom = pageTops(doc)[i + 1];
    const page = removePage(doc, i, frame.contentDocument);
    // ponytail: ink still in the undo history for the page that went (drawn there, then undone or
    // erased) comes back, on a redo, over the page that took its place. Clear the history here if that is ever met.
    ink.shift(bottom, -page.h);
    resize();
    refresh();
  }

  // ---------- gaps ----------

  // Make a gap `height` tall: the block after it ends up exactly that far below `base`, where it
  // would be without the gap. A spacer as tall as the gap moves it further, by the margin that no
  // longer shares its space (pages.js, spacerStyle): that is measured here and kept as `trim`.
  function fit(g, base, height) {
    const set = (h, trim) => {
      g.gap.height = h;
      if (trim) g.gap.trim = trim;
      else delete g.gap.trim;
      g.el.setAttribute('style', spacerStyle(g.gap)); // the very style pages.js gives it when the note is next shown
    };
    set(height, 0);
    if (!g.next) return; // at the end of the note nothing follows to be moved
    const moved = () => g.next.getBoundingClientRect().top - base;
    const spacer = Math.max(0, 2 * height - moved());
    set(height, height - spacer);
    const real = moved();
    if (Math.abs(real - height) > 0.01) set(real, real - spacer); // could not be made exact (margins taller than the gap): keep what it really is
  }

  function addGap(after, next, y) {
    const doc = note(), el = frame.contentDocument.createElement('div');
    const g = { gap: { path: pathTo(after), height: GAP }, el, after, next };
    const base = next?.getBoundingClientRect().top;
    el.setAttribute(GAP_MARK, '');
    after.after(el);
    fit(g, base, GAP);
    (doc.gaps ??= []).push(g.gap);
    open.push(g);
    ink.shift(y, g.gap.height); // also tells the app the note changed: it is saved
    resize();
    refresh();
  }

  function resizeGap(g, height) {
    const bottom = zone(g)[1], was = g.gap.height;
    fit(g, g.next && g.next.getBoundingClientRect().top - was, height);
    ink.shift(bottom, g.gap.height - was);
    resize();
    refresh();
  }

  function removeGap(g) {
    const doc = note(), bottom = zone(g)[1];
    g.el.remove();
    open = open.filter(o => o !== g);
    doc.gaps = doc.gaps.filter(gap => gap !== g.gap);
    if (!doc.gaps.length) delete doc.gaps;
    ink.shift(bottom, -g.gap.height);
    resize();
    refresh();
  }

  // The handle at the foot of a gap: while it is dragged the gap's outline follows the finger, and
  // the note and its ink follow once, when it is let go.
  // ponytail: moving the note itself with every movement would mean redrawing all the ink below
  // each time; and the window does not scroll under a drag, so a long way takes two drags.
  function drag(grip, box, g, z) {
    grip.onpointerdown = e => {
      const from = e.clientY, was = g.gap.height;
      let height = was;
      try { grip.setPointerCapture(e.pointerId); } catch { /* a pointer that is already gone */ }
      grip.onpointermove = e => {
        height = Math.round(Math.min(MAX_GAP, Math.max(MIN_GAP, was + (e.clientY - from) / z)));
        box.style.height = height * z + 'px';
      };
      grip.onpointerup = () => {
        grip.onpointermove = grip.onpointerup = null;
        if (height !== was) resizeGap(g, height);
      };
      grip.onpointercancel = refresh; // back to what it was
    };
  }

  function set(value) {
    on = value;
    button.setAttribute('aria-pressed', on);
    refresh();
  }
  button.onclick = () => set(!on);
  new ResizeObserver(refresh).observe(mover); // the sheet changes size with the zoom and with the note's height

  return {
    set,
    refresh,
    // A note has just loaded into the frame: find its gaps there (pages.js put them in).
    loaded() {
      const doc = note(), html = frame.contentDocument, blocks = doc.pages ? [] : blocksOf(html);
      open = [];
      for (const el of doc.pages ? [] : html.querySelectorAll(`[${GAP_MARK}]`)) {
        const gap = doc.gaps?.[el.getAttribute(GAP_MARK)], after = el.previousElementSibling;
        if (gap && after) open.push({ gap, el, after, next: blocks[blocks.indexOf(after) + 1 || -1] });
      }
      refresh();
    },
  };
}
