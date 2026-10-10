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
  document.body.classList.toggle('in-videos', inVideos);
  folderName.readOnly = inVideos;
  if (inVideos) return showVideos();
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
    ...(folder || !shellVideos ? [] : [videosCard()]),
    ...(folder ? [] : folders.map(f => makeFolderCard(f, notes.filter(note => home(note) === f.id).length))),
    ...here.map(note => makeCard(note, folders)),
  );
  empty.textContent = folder
    ? 'This folder is empty. Import an HTML file here, or move notes into it from the main library.'
    : 'No notes yet. Import an HTML file, or drop one anywhere on this page, to start annotating.';
  empty.hidden = here.length > 0 || (!folder && (folders.length > 0 || !!shellVideos));
}

/* Recordings (the iPad app only): the videos made with the recorder. The app keeps the files and
   does everything to them (ios/App/NoteViewController.swift); the library shows them as one more
   folder. The page asks with a message, and is sent the list as a 'recordings' event. */

const shellVideos = window.webkit?.messageHandlers?.recordings;
let videos = [];      // [{ name, size, modified }], newest first, as the app last listed them
let inVideos = false; // the library is showing them
// Every message is answered with the list as it then stands.
const askVideos = (message = { action: 'list' }) => shellVideos?.postMessage(message);
addEventListener('recordings', e => {
  videos = (Array.isArray(e.detail?.files) ? e.detail.files : [])
    .filter(v => v && typeof v.name === 'string')
    .sort((a, b) => b.modified - a.modified);
  if (!current) showLibrary();
});

const VIDEO_ICON = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="6" width="13" height="12" rx="2"/><path d="M16 10.5l5-3v9l-5-3z"/></svg>';
const SHARE_ICON = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 15V4M8 8l4-4 4 4M5 13v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5"/></svg>';
const fileSize = bytes => (bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.max(1, Math.round(bytes / 1e6))} MB`);

// The folder itself, in the main library.
function videosCard() {
  const card = folderTemplate.content.firstElementChild.cloneNode(true);
  card.classList.add('videos');
  card.querySelector('.card-open').onclick = () => {
    inVideos = true;
    askVideos();
    showLibrary();
  };
  card.querySelector('.card-thumb').innerHTML = VIDEO_ICON;
  card.querySelector('.card-name').textContent = 'Recordings';
  card.querySelector('.card-date').textContent = plural(videos.length, 'video');
  card.querySelector('.card-delete').remove(); // it is not the user's to delete
  return card;
}

function showVideos() {
  document.body.classList.add('in-folder');
  folderName.value = 'Recordings';
  grid.replaceChildren(...videos.map(makeVideoCard));
  empty.textContent = 'No recordings yet. Open a note, turn on 16:9 and tap Record.';
  empty.hidden = videos.length > 0;
}

// One recording: tap to play it; save or share it; delete it.
function makeVideoCard(video) {
  const card = cardTemplate.content.firstElementChild.cloneNode(true);
  const title = video.name.replace(/\.mov$/i, '');
  const act = action => askVideos({ action, name: video.name });
  const open = card.querySelector('.card-open');
  open.title = `Play "${title}"`;
  open.onclick = () => act('play');
  card.querySelector('.card-thumb').innerHTML = VIDEO_ICON;
  // The app names a recording by when it began, "EngiNote 2026-10-11 14.03.22", which is too long
  // for a card: shown as a date, with the time beside the size. A file renamed since keeps its name.
  const when = /^EngiNote (\d{4})-(\d\d)-(\d\d) (\d\d)\.(\d\d)\.\d\d$/.exec(title);
  const began = when && new Date(when[1], when[2] - 1, when[3], when[4], when[5]);
  card.querySelector('.card-name').textContent = began ? began.toLocaleDateString(undefined, { dateStyle: 'medium' }) : title;
  card.querySelector('.card-date').textContent =
    (began ? `${began.toLocaleTimeString(undefined, { timeStyle: 'short' })} · ` : '') + fileSize(video.size);

  const remove = card.querySelector('.card-delete');
  remove.title = 'Delete recording';
  remove.setAttribute('aria-label', 'Delete recording');
  remove.onclick = () => { if (confirm(`Delete the recording "${title}"? This cannot be undone.`)) act('delete'); };

  const save = document.createElement('button');
  save.type = 'button';
  save.className = 'icon-btn card-move'; // where a note has its "move to a folder"
  save.title = 'Save to Photos or Files, or share';
  save.setAttribute('aria-label', 'Save or share');
  save.innerHTML = SHARE_ICON;
  save.onclick = () => act('share');
  card.querySelector('.card-move').replaceWith(save);
  return card;
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

$('folder-back').onclick = () => {
  folder = null;
  inVideos = false;
  showLibrary();
};

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
//
// The fit-width zoom is a magnet: a pinch that comes within MAGNET of it is held there, the sheet
// centred across the window, until the fingers have pulled clearly past. `raw` is the zoom the
// fingers alone ask for; `zoom` is what is shown.
let pinch = null;
const MAGNET = 0.07;      // how close counts: 7% either side of the fit-width zoom
const MAGNET_PULL = 150;  // ms the sheet takes to be drawn in to the magnet, or to spring off it

function pinchMove(factor, x, y, hold) {
  pinch ??= { raw: zoom, held: false, since: -Infinity };
  pinch.raw = clampZoom(pinch.raw * factor);
  const fit = clampZoom(fitZoom()), held = Math.abs(Math.log(pinch.raw / fit)) < MAGNET;
  if (held !== pinch.held) pinch.since = performance.now();
  pinch.held = held;
  pinch.zoom = held ? fit : pinch.raw;
  const [left, top] = origin();
  pinch.at = [x - left - hold[0] * pinch.zoom, y - top - hold[1] * pinch.zoom];
  if (held) pinch.at[0] = (scroller.clientWidth - PAGE_WIDTH * fit) / 2;
  // Catching and letting go are a jump in size: for a moment the sheet eases across it instead.
  mover.style.transition = performance.now() - pinch.since < MAGNET_PULL ? 'transform .1s ease-out' : '';
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
    if (autoDeselect() && tool === 'eraser') choose(beforeEraser);
  },
});

function refreshHistory() {
  undoBtn.disabled = !ink.canUndo();
  redoBtn.disabled = !ink.canRedo();
}

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

/* ---------- Pens ---------- */

// The tray holds the user's own pens: each is a kind of pen with a colour, a thickness and an
// opacity of its own, kept on this device. `tool` is the name ink.js draws that kind with.
const PEN_TYPES = {
  pen: { name: 'Pen', tool: 'pen', size: 3, opacity: 1 },
  flow: { name: 'Flow pen', tool: 'flow', size: 4, opacity: 1 },
  glow: { name: 'Glow pen', tool: 'glow', size: 4, opacity: 1 },
  highlighter: { name: 'Highlighter', tool: 'highlighter', size: 4, opacity: 0.35 },
};
const MAX_PENS = 12; // the full-screen rail has to hold every one of them
const FIRST_PENS = [['pen', '#111111'], ['pen', '#ffffff'], ['pen', '#ff1744'], ['flow', '#1c7ed6'], ['glow', '#ffea00'], ['highlighter', '#ffea00']];
const newPen = (type, color) => ({ id: newId(), type, color, size: PEN_TYPES[type].size, opacity: PEN_TYPES[type].opacity });
const within1 = (n, low, high) => Math.min(high, Math.max(low, n));

// The saved pens, or the starting set. What comes out of storage is checked: only pens that can be drawn with.
function readPens() {
  let list;
  try { list = JSON.parse(localStorage.getItem('pens')); } catch { /* storage blocked, or not JSON */ }
  const saved = (Array.isArray(list) ? list : [])
    .filter(p => p && PEN_TYPES[p.type] && typeof p.id === 'string' && p.id !== 'eraser' && p.id !== 'hand' && /^#[0-9a-f]{6}$/i.test(p.color))
    .slice(0, MAX_PENS)
    .map(p => ({ id: p.id, type: p.type, color: p.color, size: within1(+p.size || 3, 1, 12), opacity: within1(+p.opacity || 1, 0.1, 1) }));
  return saved.length ? saved : FIRST_PENS.map(([type, color]) => newPen(type, color));
}

const pens = readPens();
const penOf = id => pens.find(p => p.id === id);
let tool = ''; // 'eraser', 'hand', or the id of the pen in use
let beforeEraser = pens[0].id; // the tool to go back to from the eraser
function savePens() {
  try {
    localStorage.setItem('pens', JSON.stringify(pens));
    if (penOf(tool)) localStorage.setItem('pen', tool);
  } catch { /* lasts for this visit only */ }
}

// A pen as a picture, standing tip up: the tip and a band take the pen's colour (--c on the button).
const PEN_TIPS = {
  pen: '<path class="tip" d="M8 1l3.5 12h-7z"/>',
  flow: '<path class="nib" d="M8 0c3 4 4 8 3 13H5C4 8 5 4 8 0z"/><path class="slit" d="M8 5v8"/>',
  glow: '<path class="tip" d="M8 1l3.5 12h-7z"/><path class="spark" d="M2.5 2v4M.5 4h4M13.5 5v3M12 6.5h3"/>',
  highlighter: '<path class="tip" d="M4.5 13V6l7-4v11z"/>',
};
const penPicture = type => `<svg viewBox="0 0 16 44" aria-hidden="true">${PEN_TIPS[type]}` +
  `<rect class="barrel" x="3.5" y="13" width="9" height="31" rx="1.5"/><rect class="band" x="3.5" y="${type === 'flow' ? 13 : 24}" width="9" height="3.5"/></svg>`;

const penBox = $('pens'), addWrap = $('add-wrap');
function renderPens() {
  penBox.replaceChildren(...pens.map((pen, i) => {
    const btn = document.createElement('button');
    const name = PEN_TYPES[pen.type].name;
    btn.type = 'button';
    btn.className = 'pen';
    btn.dataset.tool = pen.id;
    btn.title = `${name}${i < 9 ? ` (${i + 1})` : ''}. Tap again for its settings`;
    btn.setAttribute('aria-label', `${name} ${i + 1}`);
    btn.setAttribute('aria-pressed', pen.id === tool);
    btn.style.setProperty('--c', pen.color);
    btn.innerHTML = penPicture(pen.type); // fixed markup from PEN_TIPS; the colour goes in through --c
    return btn;
  }));
  addWrap.hidden = pens.length >= MAX_PENS;
}

const autoBtn = $('auto-erase'); // the eraser's option; only shown while the eraser is selected

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

// Hand the pen's own settings to the ink layer.
function usePen(pen) {
  ink.setTool(PEN_TYPES[pen.type].tool);
  ink.setColor(pen.color);
  ink.setSize(pen.size);
  ink.setOpacity(pen.opacity);
}

// Make `value` the tool: 'eraser', 'hand' or a pen's id.
function choose(value) {
  const pen = penOf(value);
  if (!pen && value !== 'eraser' && value !== 'hand') return;
  if (value === 'eraser' && tool !== 'eraser') beforeEraser = tool;
  if (value !== tool) showPanel(false);
  tool = value;
  autoBtn.hidden = value !== 'eraser';
  if (value !== 'eraser') eraserFly.set(false);
  if (pen) {
    usePen(pen);
    savePens();
  } else {
    ink.setTool(value);
  }
  for (const btn of document.querySelectorAll('[data-tool]')) btn.setAttribute('aria-pressed', btn.dataset.tool === value);
}

/* The settings of the pen in use: one panel, filled in for that pen and put beside its button. */

const editor = $('editor'), panel = $('pen-panel'), removeBtn = $('pen-remove');
const sizeRange = $('pen-size'), opacityRange = $('pen-opacity'), customColor = $('pen-custom');

function fillPanel(pen) {
  $('pen-type').textContent = PEN_TYPES[pen.type].name;
  sizeRange.value = pen.size;
  $('pen-size-out').textContent = pen.size;
  opacityRange.value = Math.round(pen.opacity * 100);
  $('pen-opacity-out').textContent = `${opacityRange.value}%`;
  let listed = false;
  for (const btn of panel.querySelectorAll('[data-color]')) {
    const on = btn.dataset.color === pen.color.toLowerCase();
    btn.setAttribute('aria-pressed', on);
    listed ||= on;
  }
  // A colour that is not one of the swatches shows on the "another colour" button.
  customColor.value = pen.color;
  customColor.parentElement.setAttribute('aria-pressed', !listed);
  customColor.parentElement.style.setProperty('--c', pen.color);
  removeBtn.disabled = pens.length < 2; // there is always a pen to write with
}

function showPanel(open) {
  const pen = penOf(tool), btn = penBox.querySelector('[aria-pressed="true"]');
  panel.hidden = !(open && pen && btn);
  if (panel.hidden) return;
  fillPanel(pen);
  // Below the toolbar under the pen, or in the full-screen rail to its left: wherever that is, kept inside the editor.
  const b = btn.getBoundingClientRect(), strip = btn.closest('.strip').getBoundingClientRect(), box = editor.getBoundingClientRect();
  const w = panel.offsetWidth, h = panel.offsetHeight, rail = document.body.classList.contains('full');
  const left = rail ? strip.left - w - 12 : b.left + b.width / 2 - w / 2;
  const top = rail ? b.top + b.height / 2 - h / 2 : strip.bottom + 10;
  panel.style.left = `${within1(left - box.left, 8, box.width - w - 8)}px`;
  panel.style.top = `${within1(top - box.top, 8, box.height - h - 8)}px`;
}
// Put away by a touch anywhere else. (Not by one on a pen: that tap has its own meaning, below.)
document.addEventListener('pointerdown', e => { if (!panel.contains(e.target) && !e.target.closest?.('.pen')) showPanel(false); });
addEventListener('resize', () => showPanel(false));

// Change the pen in use; it draws with the new setting from the next stroke on.
function editPen(change) {
  const pen = penOf(tool);
  if (!pen) return;
  Object.assign(pen, change);
  usePen(pen);
  savePens();
  penBox.querySelector('[aria-pressed="true"]')?.style.setProperty('--c', pen.color);
  fillPanel(pen);
}
sizeRange.oninput = () => editPen({ size: Number(sizeRange.value) });
opacityRange.oninput = () => editPen({ opacity: opacityRange.value / 100 });
customColor.oninput = () => editPen({ color: customColor.value });
$('pen-colors').addEventListener('click', e => {
  const color = e.target.closest('[data-color]')?.dataset.color;
  if (color) editPen({ color });
});
removeBtn.onclick = () => {
  const i = pens.findIndex(p => p.id === tool);
  if (i < 0 || pens.length < 2) return;
  pens.splice(i, 1);
  const next = pens[Math.min(i, pens.length - 1)].id;
  if (!penOf(beforeEraser)) beforeEraser = next;
  renderPens();
  choose(next);
};

// "+": a new pen of the chosen kind, in the colour of the pen in use, with its settings open.
const addFly = flyout(addWrap, $('add-pen'));
$('add-pen').onclick = addFly.toggle;
addWrap.addEventListener('click', e => {
  const type = e.target.closest('[data-add]')?.dataset.add;
  if (!type || pens.length >= MAX_PENS) return;
  addFly.set(false);
  const pen = newPen(type, type === 'highlighter' ? '#ffea00' : penOf(tool)?.color ?? '#111111');
  pens.push(pen);
  renderPens();
  choose(pen.id);
  showPanel(true);
});

$('toolbar').addEventListener('click', e => {
  const value = e.target.closest('button')?.dataset.tool;
  if (!value) return;
  if (value !== tool) return choose(value);
  // Already the tool: the tap is for its settings.
  if (value === 'eraser') eraserFly.toggle();
  else showPanel(panel.hidden);
});
undoBtn.onclick = () => ink.undo();
redoBtn.onclick = () => ink.redo();

// Flip between the eraser and the tool used before it. Bound to a finger double-tap on the page:
// Apple Pencil's own double-tap (on its barrel) is only given to native apps, never to web pages.
const toggleEraser = () => choose(tool === 'eraser' ? beforeEraser : 'eraser');

// The iPad app (ios/) passes on what a web page is never told: a double-tap or a squeeze on the
// Apple Pencil itself. It arrives as a 'pencil' event on the window; in a browser it never fires.
addEventListener('pencil', e => {
  if (!current) return;
  if (e.detail === 'tap') toggleEraser();
  else if (e.detail === 'squeeze') ink.undo();
});

// A toolbar button that switches an option on and off and remembers it on this device.
// Returns a function that reads the current state.
function option(btn, key, apply = () => {}, on = false) { // `on`: how it starts, until the user has chosen
  try { on = (localStorage.getItem(key) ?? (on ? '1' : '0')) === '1'; } catch { /* storage blocked */ }
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

let lastPen;
try { lastPen = localStorage.getItem('pen'); } catch { /* storage blocked */ }
renderPens();
choose(penOf(lastPen) ? lastPen : pens[0].id);

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

/* ---------- Screen recording (the iPad app only) ---------- */

// A page cannot record the screen; the iPad app can (ios/App/Recorder.swift). The page asks it to
// start and stop, and is told how it went by 'recorder' events on the window. The video is the
// 16:9 window; these controls sit outside it (style.css, #rec-bar).
const shellRecorder = window.webkit?.messageHandlers?.recorder;
if (shellRecorder) {
  const recBtn = $('rec-btn'), recTime = $('rec-time'), recQuality = $('rec-quality');
  const micOn = option($('rec-mic'), 'recMic', undefined, true);
  let recording = false, startedAt = 0, ticker = 0;
  document.body.classList.add('can-record');

  try { recQuality.value = localStorage.getItem('recQuality') ?? recQuality.value; } catch { /* storage blocked */ }
  if (recQuality.selectedIndex < 0) recQuality.value = 'standard'; // a saved value this version does not offer
  recQuality.onchange = () => {
    try { localStorage.setItem('recQuality', recQuality.value); } catch { /* lasts for this visit only */ }
  };

  const showTime = () => {
    const s = recording ? Math.floor((Date.now() - startedAt) / 1000) : 0;
    recTime.textContent = `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
  };
  function showRecording(on) {
    recording = on;
    document.body.classList.toggle('recording', on);
    recBtn.setAttribute('aria-pressed', on);
    $('rec-label').textContent = on ? 'Stop' : 'Record';
    // Fixed for the length of a recording: its settings, and the 16:9 window it is a picture of.
    $('rec-mic').disabled = recQuality.disabled = wideBtn.disabled = on;
    clearInterval(ticker);
    if (on) {
      startedAt = Date.now();
      ticker = setInterval(showTime, 1000);
    }
    showTime();
  }

  recBtn.onclick = () => {
    recBtn.disabled = true; // until the app answers: starting asks the user's permission, stopping finishes the file
    shellRecorder.postMessage(recording ? { action: 'stop' } : { action: 'start', quality: recQuality.value, microphone: micOn() });
  };
  addEventListener('recorder', e => {
    recBtn.disabled = false;
    showRecording(e.detail?.state === 'recording');
    if (e.detail?.message) notify(e.detail.message);
    if (!recording) askVideos(); // there may be a new one
  });
}

/* ---------- Keyboard ---------- */

const TOOL_KEYS = { e: 'eraser', v: 'hand' }; // and 1 to 9: the pens, in tray order
// The keys a browser scrolls with, as fractions of the window's height (the note is not a browser scroller: see the view section).
const SCROLL_KEYS = { pagedown: 0.9, ' ': 0.9, pageup: -0.9, arrowdown: 0.12, arrowup: -0.12 };

document.addEventListener('keydown', e => {
  if (!current || e.target instanceof HTMLInputElement) return; // typing a name, or moving a slider
  const key = e.key.toLowerCase();
  if (e.ctrlKey || e.metaKey) {
    if (key === 'z') { e.preventDefault(); e.shiftKey ? ink.redo() : ink.undo(); }
    else if (key === 'y') { e.preventDefault(); ink.redo(); }
  } else if (e.altKey) {
    // left to the browser
  } else if (TOOL_KEYS[key]) {
    choose(TOOL_KEYS[key]);
  } else if (pens[key - 1]) {
    choose(pens[key - 1].id);
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
askVideos();
