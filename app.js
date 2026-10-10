import { createInk } from './ink.js';

const PAGE_WIDTH = 900;  // fixed layout width (CSS px) so imported pages never reflow under the ink
const MIN_HEIGHT = 1200;
const GUTTER = 48;       // #scroller horizontal padding, both sides (style.css)
const MIN_ZOOM = 0.25, MAX_ZOOM = 3;

const $ = id => document.getElementById(id);
const grid = $('grid'), importTile = $('import-tile'), empty = $('empty'), fileInput = $('file-input');
const nameInput = $('note-name'), undoBtn = $('undo-btn'), redoBtn = $('redo-btn');
const scroller = $('scroller'), sizer = $('page-sizer'), page = $('page'), frame = $('frame'), svg = $('ink');
const message = $('message'), cardTemplate = $('card-template');

let current = null;      // the note open in the editor, or null in the library
let zoom = 1;
let pageHeight = MIN_HEIGHT;
let saveTimer = 0;
let messageTimer = 0;

/* ---------- Storage: IndexedDB "enginote" / store "docs" ---------- */

let dbPromise;
function openDb() {
  return dbPromise ??= new Promise((resolve, reject) => {
    const req = indexedDB.open('enginote', 1);
    req.onupgradeneeded = () => req.result.createObjectStore('docs', { keyPath: 'id' });
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function withStore(mode, run) {
  const idb = await openDb();
  return new Promise((resolve, reject) => {
    const tx = idb.transaction('docs', mode);
    const req = run(tx.objectStore('docs'));
    tx.oncomplete = () => resolve(req.result);
    tx.onerror = tx.onabort = () => reject(tx.error);
  });
}

// ponytail: all() loads every note's full html just to list names; add a metadata store if libraries get big.
const db = {
  all: () => withStore('readonly', s => s.getAll()),
  get: id => withStore('readonly', s => s.get(id)),
  put: doc => withStore('readwrite', s => s.put(doc)),
  del: id => withStore('readwrite', s => s.delete(id)),
};

/* ---------- Messages ---------- */

function notify(text) {
  message.textContent = text;
  message.hidden = false;
  clearTimeout(messageTimer);
  messageTimer = setTimeout(() => { message.hidden = true; }, 5000);
}

/* ---------- Library ---------- */

async function showLibrary() {
  document.body.classList.remove('editing');
  let docs;
  try {
    docs = await db.all();
  } catch {
    empty.textContent = 'Notes cannot be loaded because browser storage (IndexedDB) is unavailable. Try a regular, non-private window.';
    empty.hidden = false;
    return;
  }
  docs.sort((a, b) => b.updatedAt - a.updatedAt);
  grid.replaceChildren(importTile, ...docs.map(makeCard));
  empty.hidden = docs.length > 0;
}

function makeCard(doc) {
  const card = cardTemplate.content.firstElementChild.cloneNode(true);
  const open = card.querySelector('.card-open');
  open.title = doc.name;
  open.onclick = () => openDoc(doc.id);
  card.querySelector('.card-name').textContent = doc.name;
  card.querySelector('.card-date').textContent =
    new Date(doc.updatedAt).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
  card.querySelector('.card-delete').onclick = async () => {
    if (!confirm(`Delete "${doc.name}"? This cannot be undone.`)) return;
    await db.del(doc.id).catch(() => notify('Could not delete the note.'));
    showLibrary();
  };
  return card;
}

async function importFiles(fileList) {
  const files = [...fileList].filter(f => /\.html?$/i.test(f.name));
  if (!files.length) return notify('Only .html files can be imported.');
  const failed = [];
  let last;
  for (const file of files) {
    try {
      const doc = {
        // Not crypto.randomUUID(): that needs a secure context, and a tablet on http://<lan-ip> is not one.
        id: Date.now().toString(36) + Math.random().toString(36).slice(2),
        name: file.name.replace(/\.html?$/i, ''),
        html: await file.text(), // ponytail: assumes UTF-8; sniff <meta charset> if legacy encodings matter
        strokes: [],
        updatedAt: Date.now(),
      };
      await db.put(doc);
      last = doc;
    } catch {
      failed.push(file.name);
    }
  }
  if (failed.length) notify(`Could not import: ${failed.join(', ')}`);
  if (files.length === 1 && last) openDoc(last.id);
  else showLibrary();
}

$('import-btn').onclick = importTile.onclick = () => fileInput.click();
fileInput.onchange = () => {
  importFiles(fileInput.files); // copies the list synchronously, so clearing below is safe
  fileInput.value = '';         // lets the same file be picked again
};

// Always cancel the default so a dropped file never navigates the tab away; only import from the library.
document.addEventListener('dragover', e => e.preventDefault());
document.addEventListener('drop', e => {
  e.preventDefault();
  if (!current && e.dataTransfer.files.length) importFiles(e.dataTransfer.files);
});

/* ---------- Editor: page size and zoom ---------- */

page.style.width = PAGE_WIDTH + 'px';

// The sheet is scaled with a transform (layout stays exactly 900px wide at every zoom level);
// the sizer takes up the scaled size so centring and scrolling work.
function layout() {
  page.style.transform = `scale(${zoom})`;
  sizer.style.width = PAGE_WIDTH * zoom + 'px';
  sizer.style.height = pageHeight * zoom + 'px';
}

function setPageHeight(height) {
  pageHeight = height;
  frame.style.height = height + 'px';
  svg.setAttribute('viewBox', `0 0 ${PAGE_WIDTH} ${height}`);
  layout();
}

// Zoom, then scroll so that page point `hold` (in page px) sits at screen position (cx, cy).
// The buttons give neither: the point in the middle of the view stays there. The end of a pinch
// gives both: the point the fingers held stays where they left it.
// The sheet is measured after the new layout, so centring and the ends of the scroll range are
// accounted for.
function setZoom(value, cx, cy, hold) {
  const view = scroller.getBoundingClientRect();
  cx ??= view.left + view.width / 2;
  cy ??= view.top + view.height / 2;
  if (!hold) {
    const sheet = sizer.getBoundingClientRect();
    hold = [(cx - sheet.left) / zoom, (cy - sheet.top) / zoom];
  }
  zoom = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, value));
  layout();
  const sheet = sizer.getBoundingClientRect();
  scroller.scrollBy({ left: sheet.left + hold[0] * zoom - cx, top: sheet.top + hold[1] * zoom - cy, behavior: 'instant' });
  $('zoom-label').textContent = Math.round(zoom * 100) + '%';
}

// A two-finger pinch, while the fingers are down: { zoom, sheet, x, y, hold }.
// During it the sheet is only moved and scaled, by one transform on #page; the real zoom (sizer
// size and scroll position) is settled once, when the fingers lift. Doing the real thing on every
// move made the note jitter: a scroll position is a whole number of pixels, so the held point
// wobbled by up to a pixel each step, and the size change and the scroll could reach the screen a
// frame apart. It also re-laid-out and repainted the whole note at every step.
let pinch = null;

function pinchMove(factor, x, y, hold) {
  if (!pinch) {
    pinch = { zoom, sheet: sizer.getBoundingClientRect() }; // where the sheet's corner is; fixed until the fingers lift
    page.style.willChange = 'transform'; // let the browser scale what is already drawn, instead of redrawing per step
  }
  pinch.zoom = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, pinch.zoom * factor));
  Object.assign(pinch, { x, y, hold });
  const left = x - pinch.sheet.left - hold[0] * pinch.zoom, top = y - pinch.sheet.top - hold[1] * pinch.zoom;
  page.style.transform = `translate(${left}px, ${top}px) scale(${pinch.zoom})`;
  $('zoom-label').textContent = Math.round(pinch.zoom * 100) + '%';
}

function pinchEnd() {
  if (!pinch) return;
  const { zoom: reached, x, y, hold } = pinch;
  pinch = null;
  page.style.willChange = '';
  setZoom(reached, x, y, hold); // lays out for real (redrawing the note sharp at its new size) and scrolls to match
  // The scroll can only land on a whole pixel. Take up the fraction that is left with a nudge of the
  // sheet, so the note does not tick sideways as the fingers lift. (A larger gap means the scroll hit
  // the end of its range, and the note is meant to come back inside it.)
  const sheet = sizer.getBoundingClientRect();
  const dx = x - sheet.left - hold[0] * zoom, dy = y - sheet.top - hold[1] * zoom;
  if (Math.abs(dx) < 1 && Math.abs(dy) < 1) page.style.transform = `translate(${dx}px, ${dy}px) scale(${zoom})`;
}

const fitZoom = () => (scroller.clientWidth - GUTTER) / PAGE_WIDTH;

// The room for the sheet changed (tablet rotated, window resized, full screen toggled).
let lastFit = Infinity;
function refit() {
  if (!current) return;
  const fit = fitZoom();
  if (zoom === Math.min(1, lastFit)) setZoom(Math.min(1, fit)); // still at the opening zoom: follow it
  else if (zoom <= lastFit && zoom > fit) setZoom(fit);         // fitted the width before: keep it fitting
  lastFit = fit;
}
addEventListener('resize', refit);

$('zoom-out').onclick = () => setZoom(zoom / 1.25);
$('zoom-in').onclick = () => setZoom(zoom * 1.25);
$('zoom-label').onclick = () => setZoom(1);
// Two fit buttons: one in the zoom strip, one in the full-screen rail.
for (const btn of document.querySelectorAll('.fit-btn')) btn.onclick = () => setZoom(fitZoom());

// Inside the iframe 1vh is 1% of the iframe's own height, and we stretch the iframe to the full
// content height, so a `min-height: 100vh` cover would swallow the whole sheet. Rewrite height-based
// viewport lengths to px of a fixed notional screen (MIN_HEIGHT tall) before measuring.
// vmax is included because that screen is taller than PAGE_WIDTH.
function pinViewportUnits(doc) {
  const pin = style => {
    for (const prop of [...style]) {
      const value = style.getPropertyValue(prop);
      const pinned = value.replace(/(-?\d*\.?\d+)[dsl]?v(?:h|b|max)\b/g, (_, n) => n * MIN_HEIGHT / 100 + 'px');
      if (pinned !== value) style.setProperty(prop, pinned, style.getPropertyPriority(prop));
    }
  };
  const walk = rules => {
    for (const rule of rules) {
      if (rule.style) pin(rule.style);
      if (rule.cssRules) walk(rule.cssRules);
    }
  };
  for (const sheet of doc.styleSheets) {
    try { walk(sheet.cssRules); } catch { /* cross-origin stylesheet (e.g. web fonts): unreadable, skip */ }
  }
  for (const el of doc.querySelectorAll('[style]')) pin(el.style);
}

// ponytail: height is measured once, on load. Content that grows afterwards (lazy images, late web
// fonts) gets clipped; add a ResizeObserver on the iframe's documentElement if that shows up.
frame.addEventListener('load', () => {
  const doc = frame.contentDocument; // null if the document navigated itself cross-origin (meta refresh)
  if (!current || !doc?.documentElement) return;
  pinViewportUnits(doc);
  setPageHeight(Math.max(MIN_HEIGHT, doc.documentElement.scrollHeight, doc.body?.scrollHeight ?? 0));
});

/* ---------- Editor: ink, tools, saving ---------- */

const ink = createInk(svg, {
  scroller,
  onChange(strokes) {
    current.strokes = strokes;
    touch();
    refreshHistory();
  },
  onZoom: pinchMove, // two-finger pinch and pan
  onZoomEnd: pinchEnd,
  onDoubleTap: () => toggleEraser(),
  onErase() { // eraser option "auto-deselect": go back to the previous tool once something was erased
    if (autoDeselect() && tool === 'eraser') choose('tool', beforeEraser);
  },
});

function refreshHistory() {
  undoBtn.disabled = !ink.canUndo();
  redoBtn.disabled = !ink.canRedo();
}

let tool = 'pen';
let beforeEraser = 'pen'; // the tool to go back to from the eraser
const autoBtn = $('auto-erase'); // the eraser's option; only shown while the eraser is selected

// In the full-screen rail the colours hide behind one button and open as a flyout.
const colors = $('colors'), colorBtn = $('color-btn');
function openColors(open) {
  colors.classList.toggle('open', open);
  colorBtn.setAttribute('aria-expanded', open);
}
colorBtn.onclick = () => openColors(!colors.classList.contains('open'));
// Tapping anywhere else (the page included) puts the flyout away.
document.addEventListener('pointerdown', e => { if (!colors.contains(e.target)) openColors(false); });

const setters = {
  tool: v => {
    if (v === 'eraser' && tool !== 'eraser') beforeEraser = tool;
    tool = v;
    autoBtn.hidden = v !== 'eraser';
    ink.setTool(v);
  },
  color: v => {
    ink.setColor(v);
    colorBtn.style.setProperty('--c', v); // the button shows the colour in use
    openColors(false);
  },
  size: v => ink.setSize(Number(v)),
};

function choose(kind, value) {
  setters[kind](value);
  for (const btn of document.querySelectorAll(`[data-${kind}]`)) {
    btn.setAttribute('aria-pressed', btn.dataset[kind] === String(value));
  }
}

$('toolbar').addEventListener('click', e => {
  const btn = e.target.closest('button');
  if (!btn) return;
  for (const kind in setters) if (btn.dataset[kind]) choose(kind, btn.dataset[kind]);
});
undoBtn.onclick = () => ink.undo();
redoBtn.onclick = () => ink.redo();

// Flip between the eraser and the tool used before it. Bound to a finger double-tap on the page:
// Apple Pencil's own double-tap (on its barrel) is only given to native apps, never to web pages.
const toggleEraser = () => choose('tool', tool === 'eraser' ? beforeEraser : 'eraser');

// A toolbar button that switches an option on and off and remembers it on this device.
// Returns a function that reads the current state.
function option(btn, key, apply = () => {}) {
  let on = false;
  try { on = localStorage.getItem(key) === '1'; } catch { /* storage blocked */ }
  const set = value => {
    on = value;
    btn.setAttribute('aria-pressed', on);
    apply(on);
  };
  btn.onclick = () => {
    set(!on);
    try { localStorage.setItem(key, on ? '1' : '0'); } catch { /* lasts for this visit only */ }
  };
  set(on);
  return () => on;
}

const autoDeselect = option(autoBtn, 'autoDeselect');
// Off by default: fingers scroll and zoom, and only a stylus or mouse draws.
option($('finger-btn'), 'fingerDraw', on => ink.setFingerDraw(on));

choose('tool', 'pen');
choose('color', '#111111');
choose('size', 4);

// Mark the open note as changed and save it shortly.
function touch() {
  current.updatedAt = Date.now();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(save, 400);
}

function save() {
  clearTimeout(saveTimer);
  saveTimer = 0;
  return db.put(current).catch(() => notify('Could not save your changes.'));
}

// Save now if a save is pending.
const flush = () => (saveTimer ? save() : undefined);
addEventListener('pagehide', flush);

async function openDoc(id) {
  const doc = await db.get(id).catch(() => null);
  if (!doc) return notify('That note could not be opened.');
  current = doc;
  document.body.classList.add('editing'); // must be visible before fitZoom() measures the scroller
  nameInput.value = doc.name;
  setPageHeight(MIN_HEIGHT);              // reset before load so the last note's height can't inflate the measurement
  frame.srcdoc = doc.html;
  ink.load(doc.strokes || []);
  refreshHistory();
  lastFit = fitZoom();
  setZoom(Math.min(1, lastFit));
  scroller.scrollTo(0, 0);
}

async function closeDoc() {
  await flush();
  current = null;
  frame.srcdoc = ''; // drop the document; also guarantees a reload if the same note is reopened
  showLibrary();
}
$('back-btn').onclick = closeDoc;

// "change" fires on Enter and on blur, only when the text was edited.
nameInput.addEventListener('change', () => {
  current.name = nameInput.value.trim() || 'Untitled';
  nameInput.value = current.name;
  touch();
});
nameInput.addEventListener('keydown', e => {
  if (e.key === 'Enter') nameInput.blur();
});

/* ---------- Theme and full screen ---------- */

for (const btn of document.querySelectorAll('.theme-btn')) {
  btn.onclick = () => {
    const theme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = theme;
    try { localStorage.setItem('theme', theme); } catch { /* storage blocked: lasts for this visit only */ }
  };
}

// Full screen is a layout (body.full: tools in a rail on the right) plus, on desktop, real full
// screen. Not on iPad or iPhone: Safari there leaves real full screen whenever a finger drags down
// (its own exit gesture, which a page cannot turn off), so ordinary scrolling kept dropping out of
// it. There the layout alone is used; "Add to Home Screen" gives a view with no browser bars.
const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const fullBtn = $('full-btn');
function setFull(on) {
  document.body.classList.toggle('full', on);
  fullBtn.setAttribute('aria-pressed', on);
  if (on && !isIOS && !document.fullscreenElement) document.documentElement.requestFullscreen?.()?.catch(() => {});
  if (!on && document.fullscreenElement) document.exitFullscreen();
  refit();
}
const toggleFull = () => setFull(!document.body.classList.contains('full'));
fullBtn.onclick = toggleFull;
// Esc, or the browser's own exit control, leaves real full screen without telling us any other way.
document.addEventListener('fullscreenchange', () => {
  if (!document.fullscreenElement) setFull(false);
});

// 16:9: show the whole editor, tools included, in the largest 16:9 window that fits (body.wide in style.css).
const wideBtn = $('wide-btn');
wideBtn.onclick = () => {
  wideBtn.setAttribute('aria-pressed', document.body.classList.toggle('wide'));
  refit();
};

/* ---------- Keyboard ---------- */

const TOOL_KEYS = { p: 'pen', c: 'crayon', g: 'glow', h: 'highlighter', e: 'eraser', v: 'hand' };

document.addEventListener('keydown', e => {
  if (!current || e.target === nameInput) return;
  const key = e.key.toLowerCase();
  if (e.ctrlKey || e.metaKey) {
    if (key === 'z') { e.preventDefault(); e.shiftKey ? ink.redo() : ink.undo(); }
    else if (key === 'y') { e.preventDefault(); ink.redo(); }
  } else if (!e.altKey && TOOL_KEYS[key]) {
    choose('tool', TOOL_KEYS[key]);
  } else if (!e.altKey && key === 'f') {
    toggleFull();
  }
});

showLibrary();
