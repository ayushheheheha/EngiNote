// items.js — the things on a page that are not ink: text boxes and pictures. Plain ES module.
//
// A note holds them in `items`, each one a plain object that is never changed once made (a change
// is a new object, as with strokes; ink.js keeps them in its undo history beside the strokes):
//
//   { type: 'text',  x, y, w, h, text, size, color }   a box `w` wide whose text wraps in it, at `size` px
//   { type: 'image', x, y, w, h, src }                 a data:image/ URL drawn to fill x, y, w, h
//
// x and y are the top left corner in page px, w and h the size. A text box's h is how tall its text
// came to when it was written (it is only used to know where the box is: the text itself sets the height).
// They lie between the page and the ink: ink is drawn over them.

const PAGE_WIDTH = 900;      // the width every note is laid out at; the same number as in app.js and pages.js
const round2 = n => Math.round(n * 100) / 100;
const HEX = /^#[0-9a-f]{6}$/i;
const MAX_SIDE = 1800;       // px: a picture longer than this is shrunk when it is put in, so a note stays a size that can be saved
const FIRST_WIDTH = 540;     // page px: how wide a picture first is (at most)
const FIRST_HEIGHT = 720;
export const TEXT_WIDTH = 420;       // page px: how wide a new text box is (at most)
export const TEXT_SIZES = [16, 120]; // px: the least and the most a text box's text may be (a lasso resize may take it past)

export const itemBox = it => [it.x, it.y, it.x + it.w, it.y + it.h];

/** The items of a note from outside (a backup file, the store), in the shape above: those that can be drawn, and nothing else. */
export function cleanItems(list) {
  const num = (v, low, high) => Number.isFinite(v) && v >= low && v <= high;
  const made = [];
  for (const it of Array.isArray(list) ? list : []) {
    if (!it || !num(it.x, -1e5, 1e5) || !num(it.y, -1e5, 1e6) || !num(it.w, 1, 1e5) || !num(it.h, 1, 1e5)) continue;
    const at = { x: it.x, y: it.y, w: it.w, h: it.h };
    if (it.type === 'image' && typeof it.src === 'string' && it.src.startsWith('data:image/')) made.push({ type: 'image', ...at, src: it.src });
    else if (it.type === 'text' && typeof it.text === 'string' && num(it.size, 1, 2000) && HEX.test(it.color)) made.push({ type: 'text', ...at, text: it.text.slice(0, 20000), size: it.size, color: it.color.toLowerCase() });
  }
  return made;
}

/** A copy of an item scaled by k then moved by (tx, ty): where it is and how big, together (the lasso's resize). */
export function reshapeItem(it, k, tx, ty) {
  const next = { ...it, x: round2(it.x * k + tx), y: round2(it.y * k + ty), w: round2(it.w * k), h: round2(it.h * k) };
  if (it.type === 'text') next.size = Math.max(1, round2(it.size * k));
  return next;
}

const attr = text => String(text).replace(/[&<>"]/g, c => `&#${c.charCodeAt(0)};`);
// How a text box looks: one place, so that the page, a thumbnail and an export agree.
const textCss = it => `font:${it.size}px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,"Segoe UI",Roboto,sans-serif;` +
  `color:${it.color};white-space:pre-wrap;overflow-wrap:anywhere;word-break:normal;`;

/** An item as markup, placed `dy` higher than it is (for the page that starts there): for an export. */
export function itemHtml(it, dy = 0) {
  const place = `position:absolute;left:${it.x}px;top:${round2(it.y - dy)}px;width:${it.w}px;`;
  return it.type === 'image'
    ? `<img src="${attr(it.src)}" alt="" style="${place}height:${it.h}px">`
    : `<div style="${place}${textCss(it)}">${attr(it.text)}</div>`;
}

/** The picture in `file` as { src, w, h }: shrunk to a length that a note can carry, and laid out to fit a page. */
export async function readImage(file) {
  const url = URL.createObjectURL(file);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    const shrink = Math.min(1, MAX_SIDE / Math.max(img.naturalWidth, img.naturalHeight));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(img.naturalWidth * shrink));
    canvas.height = Math.max(1, Math.round(img.naturalHeight * shrink));
    canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
    // What may be see-through stays a PNG; a photograph becomes a JPEG, a fraction of the size.
    const keep = /^image\/(png|gif|webp|svg)/.test(file.type);
    const w = Math.min(FIRST_WIDTH, canvas.width, FIRST_HEIGHT * canvas.width / canvas.height);
    return { src: canvas.toDataURL(keep ? 'image/png' : 'image/jpeg', 0.86), w: round2(w), h: round2(w * canvas.height / canvas.width) };
  } finally {
    URL.revokeObjectURL(url);
  }
}

// ---------- on the page ----------

// `layer` is the element the items are drawn in: as big as the page, over its paper. `change(from, to)`
// is called when a text box is made, edited or emptied: from is the item it was (or null), to the
// item it now is (or null, if it is gone); the caller puts that into the note.
export function createItems(layer, { change }) {
  const elOf = new WeakMap();   // item -> its element: made once, for as long as the item is the same object
  let editing = null;           // { box, item, at } while a text box is being typed in: its field, the item (null if new) and where it is

  function make(it) {
    const el = it.type === 'image' ? new Image() : document.createElement('div');
    el.className = 'item';
    el.draggable = false;
    if (it.type === 'image') {
      el.alt = '';
      el.src = it.src;
      el.style.height = it.h + 'px';
    } else {
      el.style.cssText = textCss(it);
      el.textContent = it.text;
    }
    el.style.left = it.x + 'px';
    el.style.top = it.y + 'px';
    el.style.width = it.w + 'px';
    return el;
  }
  const elementOf = it => {
    let el = elOf.get(it);
    if (!el) elOf.set(it, el = make(it));
    return el;
  };

  // Show exactly these items, in order, touching only what differs (as ink.js does for strokes).
  function render(items) {
    const wanted = items.map(elementOf), keep = new Set(wanted);
    for (const el of [...layer.children]) if (!keep.has(el) && !el.classList.contains('item-edit')) el.remove();
    wanted.forEach((el, i) => { if (layer.children[i] !== el) layer.insertBefore(el, layer.children[i] || null); });
    // A box being typed in is shown by its field, not by itself.
    if (editing?.item) elementOf(editing.item).style.visibility = 'hidden';
  }

  // The lasso shows a selection moved or scaled before it is made: the item as it would be (k, then tx, ty).
  function preview(it, k, tx, ty) {
    const el = elementOf(it);
    el.style.transformOrigin = '0 0';
    el.style.transform = k === 1 && !tx && !ty ? '' : `translate(${(k - 1) * it.x + tx}px, ${(k - 1) * it.y + ty}px) scale(${k})`;
  }

  /** The top-most item that has page point `pt` in it, or undefined. */
  const hit = (items, pt, type) => [...items].reverse().find(it => (!type || it.type === type) &&
    pt[0] >= it.x && pt[0] <= it.x + it.w && pt[1] >= it.y && pt[1] <= it.y + it.h);

  // ---------- typing ----------

  // Put a field where the box is (or will be) and let the user type in it; when it is let go of, say
  // what changed. `item` is the box being edited, or null for a new one, made at page point `pt` in
  // `style` ({ size, color }).
  function start(item, pt, style) {
    finish();
    const at = item ?? (() => {
      const w = Math.min(TEXT_WIDTH, PAGE_WIDTH - 24), x = Math.max(8, Math.min(pt[0], PAGE_WIDTH - 8 - w));
      return { type: 'text', x: round2(x), y: round2(pt[1] - style.size * 0.65), w, h: 0, text: '', size: style.size, color: style.color };
    })();
    const box = document.createElement('textarea');
    box.className = 'item-edit';
    box.setAttribute('aria-label', 'Text');
    box.spellcheck = false;
    box.value = at.text;
    box.style.cssText = `${textCss(at)}left:${at.x}px;top:${at.y}px;width:${at.w}px;`;
    // Touches on the field are for the field: the window around it would take them for a stroke or a pan.
    for (const type of ['pointerdown', 'pointermove', 'pointerup', 'touchstart', 'touchmove', 'touchend', 'wheel']) box.addEventListener(type, e => e.stopPropagation());
    const fit = () => { box.style.height = '0'; box.style.height = box.scrollHeight + 'px'; };
    box.addEventListener('input', fit);
    box.addEventListener('keydown', e => { if (e.key === 'Escape') box.blur(); });
    box.addEventListener('blur', finish, { once: true });
    editing = { box, item, at };
    if (item) elementOf(item).style.visibility = 'hidden';
    layer.append(box);
    fit();
    box.focus({ preventScroll: true });
    box.setSelectionRange(box.value.length, box.value.length);
  }

  // The field is done with: the box is what was typed, or gone if nothing was.
  function finish() {
    if (!editing) return;
    const { box, item, at } = editing;
    editing = null;
    const text = box.value.replace(/\s+$/, ''), h = round2(Math.max(1, box.scrollHeight));
    box.remove();
    if (item) elementOf(item).style.visibility = '';
    if (item && !text) change(item, null);
    else if (!item && text) change(null, { ...at, text, h });
    else if (item && text !== item.text) change(item, { ...item, text, h });
  }

  // A touch anywhere but the field puts the keyboard away: the window cancels the touch events that would otherwise do it.
  document.addEventListener('pointerdown', e => { if (editing && e.target !== editing.box) editing.box.blur(); }, true);

  return { render, elementOf, preview, hit, start, finish, editing: () => !!editing };
}
