import { createInk } from './ink.js';

const PAGE_WIDTH = 900;  // fixed layout width (CSS px) so imported pages never reflow under the ink
const MIN_HEIGHT = 1200;
const GUTTER = 48;       // room kept for the grey margin on both sides of the sheet
const MIN_ZOOM = 0.25, MAX_ZOOM = 3;

const $ = id => document.getElementById(id);
const grid = $('grid'), importTile = $('import-tile'), empty = $('empty'), fileInput = $('file-input');
const nameInput = $('note-name'), undoBtn = $('undo-btn'), redoBtn = $('redo-btn');
const scroller = $('scroller'), mover = $('mover'), bar = $('scrollbar'), page = $('page'), frame = $('frame'), svg = $('ink');
const message = $('message'), cardTemplate = $('card-template'), folderTemplate = $('folder-template'), folderName = $('folder-name');

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

// The one store holds the notes and, marked type: 'folder', the folders (see the library section).
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

// Folders, one level deep. A folder is a record in the same store as the notes,
// { id, type: 'folder', name, updatedAt }, and a note in one carries its id as `folder`.
// A note whose folder is gone simply shows in the main library again, so deleting a folder is
// just deleting its record: nothing has to be moved, and no note can be lost with it.
let folder = null; // the folder the library is showing, or null for the main library

const newId = () => Date.now().toString(36) + Math.random().toString(36).slice(2); // not crypto.randomUUID(): that needs a secure context, and a tablet on http://<lan-ip> is not one
const plural = (n, word) => (n ? `${n} ${word}${n === 1 ? '' : 's'}` : 'Empty');

async function showLibrary() {
  document.body.classList.remove('editing');
  let all;
  try {
    all = await db.all();
  } catch {
    empty.textContent = 'Notes cannot be loaded because browser storage (IndexedDB) is unavailable. Try a regular, non-private window.';
    empty.hidden = false;
    return;
  }
  const folders = all.filter(d => d.type === 'folder')
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
  const notes = all.filter(d => d.type !== 'folder').sort((a, b) => b.updatedAt - a.updatedAt);
  const home = note => (folders.some(f => f.id === note.folder) ? note.folder : null); // null: the main library
  if (folder) folder = folders.find(f => f.id === folder.id) || null; // fresh copy; null if it was deleted
  const here = notes.filter(note => home(note) === (folder ? folder.id : null));

  document.body.classList.toggle('in-folder', !!folder);
  folderName.value = folder ? folder.name : '';
  grid.replaceChildren(
    importTile,
    ...(folder ? [] : folders.map(f => makeFolderCard(f, notes.filter(note => home(note) === f.id).length))),
    ...here.map(note => makeCard(note, folders)),
  );
  empty.textContent = folder
    ? 'This folder is empty. Import an HTML file here, or move notes into it from the main library.'
    : 'No notes yet. Import an HTML file, or drop one anywhere on this page, to start annotating.';
  empty.hidden = here.length > 0 || (!folder && folders.length > 0);
}

function makeCard(doc, folders) {
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

  // Moving is a native <select>, so a tablet shows its own picker: the places this note is not in.
  const move = card.querySelector('.card-move'), select = move.querySelector('select');
  const places = [...(folder ? [{ id: '', name: 'Main library' }] : []), ...folders.filter(f => f.id !== folder?.id)];
  move.hidden = places.length === 0;
  select.replaceChildren(new Option('Move to…', '', true, true), ...places.map(p => new Option(p.name, p.id)));
  select.options[0].disabled = true;
  select.onchange = async () => {
    const to = select.value; // '' is the main library
    if (to) doc.folder = to;
    else delete doc.folder;
    await db.put(doc).catch(() => notify('Could not move the note.'));
    showLibrary();
  };
  return card;
}

function makeFolderCard(f, count) {
  const card = folderTemplate.content.firstElementChild.cloneNode(true);
  const open = card.querySelector('.card-open');
  open.title = f.name;
  open.onclick = () => { folder = f; showLibrary(); };
  card.querySelector('.card-name').textContent = f.name;
  card.querySelector('.card-date').textContent = plural(count, 'note');
  card.querySelector('.card-delete').onclick = async () => {
    const kept = count ? ` Its ${plural(count, 'note')} will not be deleted: ${count === 1 ? 'it goes' : 'they go'} back to the main library.` : '';
    if (!confirm(`Delete the folder "${f.name}"?${kept}`)) return;
    await db.del(f.id).catch(() => notify('Could not delete the folder.'));
    showLibrary();
  };
  return card;
}

$('new-folder').onclick = async () => {
  const taken = new Set((await db.all().catch(() => [])).filter(d => d.type === 'folder').map(d => d.name));
  let name = 'New folder';
  for (let n = 2; taken.has(name); n++) name = `New folder ${n}`;
  const made = { id: newId(), type: 'folder', name, updatedAt: Date.now() };
  try {
    await db.put(made);
  } catch {
    return notify('Could not create the folder.');
  }
  folder = made;
  await showLibrary();
  folderName.focus(); // straight into naming it
  folderName.select();
};

$('folder-back').onclick = () => { folder = null; showLibrary(); };

// "change" fires on Enter and on blur, only when the text was edited.
folderName.addEventListener('change', () => {
  if (!folder) return;
  folder.name = folderName.value.trim() || 'Untitled folder';
  folder.updatedAt = Date.now(); // so a restore from an older backup does not undo the rename
  folderName.value = folder.name;
  db.put(folder).catch(() => notify('Could not rename the folder.'));
});
folderName.addEventListener('keydown', e => {
  if (e.key === 'Enter') folderName.blur();
});

/* ---------- Backup ---------- */

// Everything this app has stored, notes and folders, as one JSON file, and back again. The notes
// live only in this browser's (or the iPad app's) own storage, so a backup file kept somewhere
// else is the one thing that survives the app being removed.
const backupFly = flyout($('backup-wrap'), $('backup-btn'));
$('backup-btn').onclick = backupFly.toggle;

$('backup-save').onclick = async () => {
  backupFly.set(false);
  let docs;
  try {
    docs = await db.all();
  } catch {
    return notify('Could not read the notes to back them up.');
  }
  const text = JSON.stringify({ app: 'EngiNote', version: 1, savedAt: new Date().toISOString(), docs });
  const name = `EngiNote backup ${new Date().toLocaleDateString('en-CA')}.json`; // en-CA writes the local date as 2026-10-11
  // In the iPad app a page cannot save a file by itself: the shell does it (ios/App/NoteViewController.swift).
  const shell = window.webkit?.messageHandlers?.saveFile;
  if (shell) return shell.postMessage({ name, text });
  const link = document.createElement('a');
  link.href = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 60000);
};

// A backup file comes from outside, so nothing in it is taken on trust: only records shaped like
// the ones this app writes are used, and only the fields it knows.
function fromBackup(d) {
  if (!d || typeof d.id !== 'string' || !d.id || typeof d.name !== 'string' || !Number.isFinite(d.updatedAt)) return null;
  if (d.type === 'folder') return { id: d.id, type: 'folder', name: d.name, updatedAt: d.updatedAt };
  if (typeof d.html !== 'string' || !Array.isArray(d.strokes)) return null;
  const note = { id: d.id, name: d.name, html: d.html, strokes: d.strokes, updatedAt: d.updatedAt };
  if (typeof d.folder === 'string') note.folder = d.folder;
  return note;
}

const backupInput = $('backup-input');
$('backup-load').onclick = () => {
  backupFly.set(false);
  backupInput.click();
};
backupInput.onchange = async () => {
  const file = backupInput.files[0];
  backupInput.value = ''; // lets the same file be picked again
  if (!file) return;
  let records;
  try {
    const data = JSON.parse(await file.text());
    if (!data || data.app !== 'EngiNote' || !Array.isArray(data.docs)) throw new Error('not a backup');
    records = data.docs.map(fromBackup).filter(Boolean);
  } catch {
    return notify('That file is not an EngiNote backup.');
  }
  // Restoring only ever adds: a record is written if it is missing here, or older here than in
  // the backup. Nothing is deleted, and nothing newer is overwritten.
  let notes = 0, folders = 0;
  try {
    const here = new Map((await db.all()).map(d => [d.id, d]));
    for (const record of records) {
      const mine = here.get(record.id);
      if (mine && mine.updatedAt >= record.updatedAt) continue;
      await db.put(record);
      if (record.type === 'folder') folders++;
      else notes++;
    }
  } catch {
    notify('The restore stopped part way: storage could not be written.');
    return showLibrary();
  }
  const count = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
  notify(notes + folders
    ? `Restored ${[notes && count(notes, 'note'), folders && count(folders, 'folder')].filter(Boolean).join(' and ')}.`
    : 'Nothing to restore: everything in that backup is already here.');
  showLibrary();
};

async function importFiles(fileList) {
  const files = [...fileList].filter(f => /\.html?$/i.test(f.name));
  if (!files.length) return notify('Only .html files can be imported.');
  const failed = [];
  let last;
  for (const file of files) {
    try {
      const doc = {
        id: newId(),
        name: file.name.replace(/\.html?$/i, ''),
        html: await file.text(), // ponytail: assumes UTF-8; sniff <meta charset> if legacy encodings matter
        strokes: [],
        updatedAt: Date.now(),
      };
      if (folder) doc.folder = folder.id; // imported inside a folder: it belongs there
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

/* ---------- Editor: the view (where the sheet sits in the window, and how big) ---------- */

page.style.width = PAGE_WIDTH + 'px';

// The browser does not scroll the note. #scroller is a fixed window, and this code alone places the
// sheet in it: `pos` is where the sheet's top-left corner sits, in px from the window's own top-left
// corner, and `zoom` is its scale. A finger, the wheel, the keys, a pinch and the zoom buttons all
// just change those two and call place().
//
// The note used to live in a real scrolling box, and every zoom had to end by turning its position
// into a scroll position. On an iPad that hand-over kept going wrong (the note sat right during a
// pinch, then jumped as the fingers lifted) in ways a desktop browser never showed. Now there is
// no hand-over: what a pinch shows is what stays.
//
// Two elements, so that moving is cheap and text stays sharp:
//   #mover  is translated to `pos`. It is its own compositing layer (will-change in style.css), so
//           moving it redraws nothing.
//   #page   inside it is scaled to `zoom`, and is redrawn whenever that changes.
let pos = [0, 0];
const MARGIN = GUTTER / 2; // the grey band kept around the sheet

const clampZoom = value => Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, value));
const showZoom = (value = zoom) => { $('zoom-label').textContent = Math.round(value * 100) + '%'; };

// The window's top-left corner on screen.
function origin() {
  const box = scroller.getBoundingClientRect();
  return [box.left + scroller.clientLeft, box.top + scroller.clientTop];
}

// `at`, brought back within bounds: the sheet may not leave the window (its margin may just show),
// and it sits centred when it is narrower than the window.
function within([x, y]) {
  const w = PAGE_WIDTH * zoom, h = pageHeight * zoom, vw = scroller.clientWidth, vh = scroller.clientHeight;
  return [
    w + GUTTER <= vw ? (vw - w) / 2 : Math.min(MARGIN, Math.max(vw - w - MARGIN, x)),
    h + GUTTER <= vh ? MARGIN : Math.min(MARGIN, Math.max(vh - h - MARGIN, y)),
  ];
}

// Put the sheet at `at` (kept within bounds). `glide`: slide there instead of jumping.
function place(at = pos, glide = false) {
  pos = within(at);
  // Drawn on whole device pixels, where text is sharpest; `pos` itself keeps the fractions, so
  // slow finger movement still adds up.
  const snap = v => Math.round(v * devicePixelRatio) / devicePixelRatio;
  mover.style.transition = glide ? 'transform .2s ease-out' : '';
  mover.style.transform = `translate(${snap(pos[0])}px, ${snap(pos[1])}px)`;
  // The thin bar at the right edge: how far down the note the window is.
  const h = pageHeight * zoom + GUTTER, vh = scroller.clientHeight, length = Math.max(28, vh * vh / h);
  bar.hidden = h <= vh;
  bar.style.height = length + 'px';
  bar.style.transform = `translateY(${(MARGIN - pos[1]) / (h - vh) * (vh - length)}px)`;
}

// Move the view by a scroll amount: positive goes right / down the note.
const panBy = (dx, dy) => place([pos[0] - dx, pos[1] - dy]);

// Size the sheet for the current zoom. Callers place() it afterwards.
function layout() {
  mover.style.width = PAGE_WIDTH * zoom + 'px';
  mover.style.height = pageHeight * zoom + 'px';
  page.style.transform = `scale(${zoom})`;
}

function setPageHeight(height) {
  pageHeight = height;
  frame.style.height = height + 'px';
  svg.setAttribute('viewBox', `0 0 ${PAGE_WIDTH} ${height}`);
  layout();
  place();
}

// Set the zoom outright and go to the top of the note: for opening one.
function resetZoom(value) {
  zoom = clampZoom(value);
  layout();
  place([0, MARGIN]);
  showZoom();
}

// Zoom so that page point `hold` (in page px) stays at screen position (cx, cy), as far as the
// bounds allow. The buttons give neither: the point in the middle of the window stays there.
function setZoom(value, cx, cy, hold) {
  const [left, top] = origin();
  cx ??= left + scroller.clientWidth / 2;
  cy ??= top + scroller.clientHeight / 2;
  hold ??= [(cx - left - pos[0]) / zoom, (cy - top - pos[1]) / zoom];
  zoom = clampZoom(value);
  layout();
  place([cx - left - hold[0] * zoom, cy - top - hold[1] * zoom]);
  showZoom();
}

// A two-finger pinch, while the fingers are down: { zoom, at }. #page keeps the scale it is drawn
// at; the rest of the zoom is a scale on #mover, which the browser does by stretching the picture
// it already has. So a pinch redraws nothing and lays out nothing, and the point the fingers hold
// stays under them to a fraction of a pixel. The note is redrawn sharp once, when they lift.
let pinch = null;

function pinchMove(factor, x, y, hold) {
  pinch ??= { zoom };
  pinch.zoom = clampZoom(pinch.zoom * factor);
  const [left, top] = origin();
  pinch.at = [x - left - hold[0] * pinch.zoom, y - top - hold[1] * pinch.zoom];
  mover.style.transition = '';
  mover.style.transform = `translate(${pinch.at[0]}px, ${pinch.at[1]}px) scale(${pinch.zoom / zoom})`;
  showZoom(pinch.zoom);
}

function pinchEnd() {
  if (!pinch) return;
  const { zoom: reached, at } = pinch;
  pinch = null;
  // The same picture, now at its real size: the sheet takes the scale, the mover goes back to a
  // plain move to the very spot the fingers left it.
  zoom = reached;
  layout();
  mover.style.transition = '';
  mover.style.transform = `translate(${at[0]}px, ${at[1]}px)`;
  mover.getBoundingClientRect(); // let that take effect before the next line, so a glide starts from here
  place(at, true);               // if the fingers left it past an edge, it slides back inside
  showZoom();
}

const fitZoom = () => (scroller.clientWidth - GUTTER) / PAGE_WIDTH;

// The room for the sheet changed (tablet rotated, window resized, full screen toggled).
let lastFit = Infinity;
function refit() {
  if (!current) return;
  const fit = fitZoom();
  if (zoom === Math.min(1, lastFit)) setZoom(Math.min(1, fit)); // still at the opening zoom: follow it
  else if (zoom <= lastFit && zoom > fit) setZoom(fit);         // fitted the width before: keep it fitting
  else place();                                                 // same zoom, new bounds
  lastFit = fit;
}
addEventListener('resize', refit);

$('zoom-out').onclick = () => setZoom(zoom / 1.25);
$('zoom-in').onclick = () => setZoom(zoom * 1.25);
$('zoom-label').onclick = () => setZoom(1);
// Two fit buttons: one in the zoom strip, one in the full-screen rail.
for (const btn of document.querySelectorAll('.fit-btn')) btn.onclick = () => setZoom(fitZoom());

// Mouse wheel and trackpad. Ctrl + wheel, which is also what a trackpad pinch sends, zooms about the pointer.
scroller.addEventListener('wheel', e => {
  e.preventDefault();
  const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? scroller.clientHeight : 1; // lines and pages, in px
  if (e.ctrlKey) setZoom(zoom * Math.exp(-e.deltaY * unit / 300), e.clientX, e.clientY);
  else panBy(e.deltaX * unit, e.deltaY * unit);
}, { passive: false });

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
  surface: scroller, // fingers pan and pinch anywhere in the window, grey margin included
  scroller: { scrollBy: ({ left = 0, top = 0 }) => panBy(left, top) }, // ink.js scrolls through this; see the view section
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

// A flyout: a panel that opens beside its button (`wrap` holds both) and is put away by a touch
// anywhere outside it, the page included.
function flyout(wrap, button) {
  const set = open => {
    wrap.classList.toggle('open', open);
    button.setAttribute('aria-expanded', open);
  };
  document.addEventListener('pointerdown', e => { if (!wrap.contains(e.target)) set(false); });
  return { set, toggle: () => set(!wrap.classList.contains('open')) };
}

// In the full-screen rail the colours hide behind one button and open as a flyout.
const colorBtn = $('color-btn'), colorFly = flyout($('colors'), colorBtn);
colorBtn.onclick = colorFly.toggle;

// The eraser's size: a slider in a flyout, opened by tapping the eraser button while it is already the tool.
const eraserBtn = document.querySelector('[data-tool="eraser"]'), eraserFly = flyout($('eraser-wrap'), eraserBtn);
const eraserRange = $('eraser-range'), eraserDot = $('eraser-dot');
function setEraserSize(radius) {
  ink.setEraserSize(radius);
  eraserRange.value = radius;
  eraserDot.style.width = eraserDot.style.height = radius + 4 + 'px'; // a picture of the size, not to scale: 8 to 44px for 4 to 40
}
eraserRange.oninput = () => {
  setEraserSize(Number(eraserRange.value));
  try { localStorage.setItem('eraserSize', eraserRange.value); } catch { /* lasts for this visit only */ }
};

const setters = {
  tool: v => {
    if (v === 'eraser' && tool !== 'eraser') beforeEraser = tool;
    tool = v;
    autoBtn.hidden = v !== 'eraser';
    if (v !== 'eraser') eraserFly.set(false);
    ink.setTool(v);
  },
  color: v => {
    ink.setColor(v);
    colorBtn.style.setProperty('--c', v); // the button shows the colour in use
    colorFly.set(false);
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
  if (btn === eraserBtn && tool === 'eraser') return eraserFly.toggle(); // already the tool: the tap is for its size
  for (const kind in setters) if (btn.dataset[kind]) choose(kind, btn.dataset[kind]);
});
undoBtn.onclick = () => ink.undo();
redoBtn.onclick = () => ink.redo();

// Flip between the eraser and the tool used before it. Bound to a finger double-tap on the page:
// Apple Pencil's own double-tap (on its barrel) is only given to native apps, never to web pages.
const toggleEraser = () => choose('tool', tool === 'eraser' ? beforeEraser : 'eraser');

// The iPad app (ios/) passes on what a web page is never told: a double-tap or a squeeze on the
// Apple Pencil itself. It arrives as a 'pencil' event on the window; in a browser it never fires.
addEventListener('pencil', e => {
  if (!current) return;
  if (e.detail === 'tap') toggleEraser();
  else if (e.detail === 'squeeze') ink.undo();
});

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

let savedEraser = 0;
try { savedEraser = Number(localStorage.getItem('eraserSize')); } catch { /* storage blocked */ }
setEraserSize(savedEraser >= Number(eraserRange.min) && savedEraser <= Number(eraserRange.max) ? savedEraser : 8);

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
  resetZoom(Math.min(1, lastFit));
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
// The keys a browser scrolls with, as fractions of the window's height (the note is not a browser scroller: see the view section).
const SCROLL_KEYS = { pagedown: 0.9, ' ': 0.9, pageup: -0.9, arrowdown: 0.12, arrowup: -0.12 };

document.addEventListener('keydown', e => {
  if (!current || e.target === nameInput) return;
  const key = e.key.toLowerCase();
  if (e.ctrlKey || e.metaKey) {
    if (key === 'z') { e.preventDefault(); e.shiftKey ? ink.redo() : ink.undo(); }
    else if (key === 'y') { e.preventDefault(); ink.redo(); }
  } else if (e.altKey) {
    // left to the browser
  } else if (TOOL_KEYS[key]) {
    choose('tool', TOOL_KEYS[key]);
  } else if (key === 'f') {
    toggleFull();
  } else if (key in SCROLL_KEYS) {
    e.preventDefault();
    panBy(0, SCROLL_KEYS[key] * scroller.clientHeight * (e.shiftKey && key === ' ' ? -1 : 1));
  } else if (key === 'home' || key === 'end') {
    e.preventDefault();
    place([pos[0], key === 'home' ? MARGIN : -Infinity]);
  }
});

showLibrary();
