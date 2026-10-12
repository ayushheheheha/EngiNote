import { createInk, strokeData, strokeWidth, opacityOf } from './ink.js';
import { createLasso } from './lasso.js';
import { noteHtml, pagesHeight, paperHeight, addPage, needsPage, cleanPages, cleanPaper, cleanGaps, pageTops, pageStyle, rearrange, inkedPages } from './pages.js';
import { askNotebook } from './notebook.js';
import { createSpace } from './space.js';
import { exportDoc, printDoc, pinUnits } from './export.js';
import { createThumbs } from './thumbs.js';
import { createGhost } from './ghost.js';
import { createItems, cleanItems, readImage, itemHtml, TEXT_SIZES } from './items.js';

const PAGE_WIDTH = 900;  // fixed layout width (CSS px) so imported pages never reflow under the ink
const MIN_HEIGHT = 1200;
const GUTTER = 48;       // room kept for the grey margin on both sides of the sheet
const MIN_ZOOM = 0.25, MAX_ZOOM = 3;

const $ = id => document.getElementById(id);
const grid = $('grid'), importTile = $('import-tile'), empty = $('empty'), fileInput = $('file-input');
const nameInput = $('note-name'), undoBtn = $('undo-btn'), redoBtn = $('redo-btn');
const scroller = $('scroller'), mover = $('mover'), bar = $('scrollbar'), page = $('page'), frame = $('frame'), svg = $('ink');
const message = $('message'), cardTemplate = $('card-template'), folderName = $('folder-name');

// The Android app (android/) gives the page one doorway, window.AndroidShell, that takes JSON text:
// { type: 'save', name, text } to keep a file, { type: 'print', name, html } to print or save a PDF.
const androidPost = window.AndroidShell && (body => window.AndroidShell.postMessage(JSON.stringify(body)));

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

let tab = 'all'; // which notes the tabs show: all of them, the notebooks made here, or what was imported

async function showLibrary() {
  document.body.classList.remove('editing');
  previews.disconnect(); // the cards are about to be made afresh
  document.body.classList.toggle('in-videos', inVideos);
  let all;
  try {
    all = await db.all();
  } catch {
    empty.textContent = 'Notes cannot be loaded because browser storage (IndexedDB) is unavailable. Try a regular, non-private window.';
    empty.hidden = false;
    return;
  }
  const folders = all.filter(d => d.type === 'folder').sort(byName);
  const notes = all.filter(d => d.type !== 'folder').sort(sortBy.value === 'name' ? byName : (a, b) => b.updatedAt - a.updatedAt);
  const home = note => (folders.some(f => f.id === note.folder) ? note.folder : null); // null: the main library
  if (folder) folder = folders.find(f => f.id === folder.id) || null; // fresh copy; null if it was deleted
  drawSide(folders, notes, home);
  if (inVideos) return showVideos();
  // A search shows the notes with the typed words in their name and nothing else: no import tile.
  // From the main library it looks in every folder too; in a folder, in that folder.
  // (Read here, after the wait for storage: typing fast, every call then shows the latest words.)
  const query = search.value.trim().toLowerCase();
  const here = notes.filter(note => (query && !folder) || home(note) === (folder ? folder.id : null))
    .filter(note => note.name.toLowerCase().includes(query))
    .filter(note => tab === 'all' || (tab === 'notebook') === !!note.paper); // a notebook is made here from a paper; the rest came in as files

  document.body.classList.toggle('in-folder', !!folder);
  folderName.value = folder ? folder.name : query ? 'Search' : 'Unfiled';
  folderName.readOnly = !folder;
  grid.replaceChildren(...(query ? [] : [importTile]), ...here.map(note => makeCard(note, folders)));
  empty.textContent = query ? `No notes ${folder ? 'in this folder ' : ''}match "${search.value.trim()}".`
    : tab !== 'all' ? `No ${tab === 'notebook' ? 'notebooks' : 'imported notes'} here.`
    : folder ? 'This folder is empty. Tap Create to start a notebook here, or move notes into it from Unfiled.'
    : 'No notes yet. Tap Create to start a notebook, or import an HTML or PDF file with the + at the top.';
  empty.hidden = here.length > 0;
}

// The sidebar: where the notes are kept, with how many each place holds, and where the library now is.
const sideAll = $('side-all'), sideVideos = $('side-videos'), sideFolders = $('side-folders');
const FOLDER_ICON = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>';
function drawSide(folders, notes, home) {
  const count = (item, n) => { item.querySelector('.side-count').textContent = n || ''; };
  count(sideAll, notes.filter(note => !home(note)).length);
  sideAll.classList.toggle('on', !folder && !inVideos);
  sideVideos.hidden = !shellVideos;
  sideVideos.classList.toggle('on', inVideos);
  count(sideVideos, videos.length);
  sideFolders.replaceChildren(...folders.map(f => {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'side-item sub';
    item.classList.toggle('on', !inVideos && folder?.id === f.id);
    item.innerHTML = `${FOLDER_ICON}<span></span><b class="side-count"></b>`;
    item.querySelector('span').textContent = f.name;
    count(item, notes.filter(note => note.folder === f.id).length);
    item.onclick = () => goTo(f, false);
    return item;
  }));
}
// Go to a folder (null: Unfiled), or to the recordings. A narrow screen then puts the sidebar away.
function goTo(where, videosToo) {
  folder = where;
  inVideos = videosToo;
  search.value = ''; // a search would be looking in the wrong place
  if (videosToo) askVideos();
  leaveSide();
  showLibrary();
}
sideAll.onclick = () => goTo(null, false);
sideVideos.onclick = () => goTo(null, true);

// The tabs above the notes.
const tabs = $('tabs');
tabs.onclick = e => {
  const button = e.target.closest('[data-tab]');
  if (!button) return;
  tab = button.dataset.tab;
  for (const b of tabs.children) b.setAttribute('aria-pressed', b === button);
  showLibrary();
};

// The sidebar stays beside the notes where there is room; where there is not, it comes over them and
// goes away again after a choice. Either way it can be hidden, and that is remembered.
const narrow = matchMedia('(max-width: 899px)');
function setSide(hidden, remember) {
  document.body.classList.toggle('side-hidden', hidden);
  if (remember) try { localStorage.setItem('sideHidden', hidden ? '1' : '0'); } catch { /* lasts for this visit only */ }
}
const leaveSide = () => { if (narrow.matches) setSide(true); };
let savedSide = null;
try { savedSide = localStorage.getItem('sideHidden'); } catch { /* storage blocked */ }
setSide(savedSide === null ? narrow.matches : savedSide === '1');
$('side-hide').onclick = () => setSide(true, true);
$('side-show').onclick = () => setSide(false, true);
$('lib-main').addEventListener('pointerdown', leaveSide);

// Search and sort (the capsule in the library's bar). Both just show the library again.
// ponytail: every keystroke makes the cards, and so their pictures, afresh. If typing ever drags in
// a big library, keep the cards between calls and only hide the ones that do not match.
const search = $('search'), sortBy = $('sort');
const byName = (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }); // "Note 2" before "Note 10"
try { sortBy.value = localStorage.getItem('sort') ?? sortBy.value; } catch { /* storage blocked */ }
if (sortBy.selectedIndex < 0) sortBy.value = 'edited'; // a saved value this version does not offer
sortBy.onchange = () => {
  try { localStorage.setItem('sort', sortBy.value); } catch { /* lasts for this visit only */ }
  showLibrary();
};
search.oninput = () => showLibrary();
$('search-clear').onclick = () => {
  search.value = '';
  search.focus();
  showLibrary();
};

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
const EDIT_ICON = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M8.5 8l11 9M8.5 16l11-9"/></svg>';
const fileSize = bytes => (bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.max(1, Math.round(bytes / 1e6))} MB`);

function showVideos() {
  document.body.classList.add('in-folder');
  folderName.value = 'Recordings';
  folderName.readOnly = true;
  grid.replaceChildren(...videos.map(makeVideoCard));
  empty.textContent = 'No recordings yet. Open a note, turn on 16:9 and tap Record.';
  empty.hidden = videos.length > 0;
}

// One recording: tap to play it; save or share it; delete it.
function makeVideoCard(video) {
  const card = cardTemplate.content.firstElementChild.cloneNode(true);
  const title = video.name.replace(/\.(mov|mp4)$/i, '');
  const act = action => askVideos({ action, name: video.name });
  const open = card.querySelector('.card-open');
  card.classList.add('video');
  wireMore(card);
  open.title = `Play "${title}"`;
  open.onclick = () => act('play');
  const thumb = card.querySelector('.card-thumb');
  thumb.innerHTML = VIDEO_ICON;
  if (typeof video.picture === 'string' && video.picture.startsWith('data:image/jpeg;base64,')) {
    const img = new Image(); // a frame of the video, made by the app; the icon stays under it until it loads
    img.className = 'card-picture';
    img.alt = '';
    img.onload = () => { thumb.append(img); card.classList.add('pictured'); }; // pictured: its buttons get a ground to be seen on
    img.src = video.picture;
  }
  // The app names a recording by its note and when it began, "Thermodynamics 2026-10-11 14.03.22" (older
  // ones "EngiNote 2026-10-11 14.03.22"). That is too long for a card: the note's name, then the date and
  // time beside the size. Older ones show the date as the name. A file renamed since keeps its name.
  const when = /^(.*) (\d{4})-(\d\d)-(\d\d) (\d\d)\.(\d\d)\.\d\d$/.exec(title);
  const began = when && new Date(when[2], when[3] - 1, when[4], when[5], when[6]);
  const stamp = began && `${began.toLocaleDateString(undefined, { dateStyle: 'medium' })}, ${began.toLocaleTimeString(undefined, { timeStyle: 'short' })}`;
  const noted = when && when[1] !== 'EngiNote'; // named for a note
  card.querySelector('.card-name').textContent = noted ? when[1] : began ? began.toLocaleDateString(undefined, { dateStyle: 'medium' }) : title;
  card.querySelector('.card-date').textContent =
    (noted ? `${stamp} · ` : began ? `${began.toLocaleTimeString(undefined, { timeStyle: 'short' })} · ` : '') + fileSize(video.size);

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
  const edit = card.querySelector('.card-copy'); // a recording is not duplicated: its button trims and cuts it instead
  edit.title = 'Trim or cut this recording';
  edit.setAttribute('aria-label', 'Edit recording');
  edit.innerHTML = EDIT_ICON;
  edit.onclick = () => act('edit');
  return card;
}

/* A card shows the top of its note, ink and all, rather than a blank sheet. The picture is the
   note itself, in a frame of its own with scripts off, as wide as the editor lays it out
   (PAGE_WIDTH) and shrunk to the card (--thumb-scale, style.css), with the strokes drawn over it.
   A note is only loaded into its card when the card comes near the screen.
   ponytail: each picture is a live document. If a library of hundreds ever drags, keep a small
   drawn picture with each note instead, made when the note is closed. */

const SVG_NS = 'http://www.w3.org/2000/svg';
const THUMB_H = PAGE_WIDTH * 4 / 3; // a card's picture is the top of the note, as tall as a page is wide, three to four
const PREVIEW_STROKES = 400; // more than can be told apart at this size
const previewOf = new WeakMap(); // the card's picture frame -> its note
const previews = new IntersectionObserver(entries => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    previews.unobserve(entry.target);
    fillPreview(entry.target, previewOf.get(entry.target));
  }
}, { rootMargin: '300px' });

function fillPreview(box, doc) {
  const frame = document.createElement('iframe');
  frame.setAttribute('sandbox', ''); // an imported file is not trusted: no scripts, no access to anything
  frame.setAttribute('scrolling', 'no');
  frame.tabIndex = -1;
  frame.title = '';
  frame.onload = () => box.classList.add('ready');
  frame.srcdoc = noteHtml(doc); // the note as it is shown (pages.js): a notebook's pages, a file with its gaps

  // The ink: only strokes that begin in the part of the note the card shows, drawn plainly
  // (a glow stroke without its halo). The viewBox is the frame's own size, so it lines up with it at any card size.
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', `0 0 ${PAGE_WIDTH} ${THUMB_H}`);
  svg.setAttribute('preserveAspectRatio', 'xMinYMin slice');
  const seen = (Array.isArray(doc.strokes) ? doc.strokes : []).filter(s => s?.points?.[0]?.[1] < THUMB_H).slice(0, PREVIEW_STROKES);
  for (const s of seen) {
    try { // a stroke that cannot be drawn (a note from a damaged backup) is left out, not fatal
      const path = document.createElementNS(SVG_NS, 'path');
      const outline = s.tool === 'flow' || s.points[0].length > 2;
      path.setAttribute('d', strokeData(s));
      path.setAttribute('fill', outline ? s.color : 'none');
      if (!outline) {
        path.setAttribute('stroke', s.color);
        path.setAttribute('stroke-width', strokeWidth(s));
        path.setAttribute('stroke-linecap', 'round');
        path.setAttribute('stroke-linejoin', 'round');
      }
      path.setAttribute('opacity', opacityOf(s));
      svg.appendChild(path);
    } catch { /* skip it */ }
  }
  // Text boxes and pictures, in a layer as big as the page and shrunk like the frame.
  const things = document.createElement('div');
  things.className = 'card-items';
  for (const it of cleanItems(doc.items)) if (it.y < THUMB_H) things.insertAdjacentHTML('beforeend', itemHtml(it));
  box.replaceChildren(frame, things, svg);
}

// Every card is the same width: one number scales all the pictures. The grid's cards change width with the window.
new ResizeObserver(() => {
  const box = grid.querySelector('.card-preview');
  if (box?.clientWidth) grid.style.setProperty('--thumb-scale', box.clientWidth / PAGE_WIDTH);
}).observe(grid);

function makeCard(doc, folders) {
  const card = cardTemplate.content.firstElementChild.cloneNode(true);
  const open = card.querySelector('.card-open');
  const at = folders.find(f => f.id === doc.folder); // the folder this note is in, if any
  card.dataset.id = doc.id;
  open.title = doc.name;
  open.onclick = () => openDoc(doc.id);
  const picture = document.createElement('div');
  picture.className = 'card-preview';
  previewOf.set(picture, doc);
  previews.observe(picture);
  card.querySelector('.card-thumb').append(picture); // over the blank sheet; a tap on it goes through to the card
  card.classList.add('pictured');
  wireMore(card);
  card.querySelector('.card-name').textContent = doc.name;
  // Only a search shows a note outside its folder: the card then says which one it is in.
  card.querySelector('.card-date').textContent = (at && !folder ? `In ${at.name} · ` : '') +
    new Date(doc.updatedAt).toLocaleDateString(undefined, { dateStyle: 'medium' });
  card.querySelector('.card-delete').onclick = async () => {
    if (!confirm(`Delete "${doc.name}"? This cannot be undone.`)) return;
    await db.del(doc.id).catch(() => notify('Could not delete the note.'));
    showLibrary();
  };
  card.querySelector('.card-copy').onclick = () => duplicate(doc);

  // Moving is a native <select>, so a tablet shows its own picker: the places this note is not in.
  const move = card.querySelector('.card-move'), select = move.querySelector('select');
  const places = [...(at ? [{ id: '', name: 'Main library' }] : []), ...folders.filter(f => f !== at)];
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

// A card's duplicate, move and delete are behind its "more" button; a touch anywhere else puts them away.
function wireMore(card) {
  const more = card.querySelector('.card-more');
  more.onclick = () => {
    const open = !card.classList.contains('acting');
    closeActions();
    card.classList.toggle('acting', open);
    more.setAttribute('aria-expanded', open);
  };
}
function closeActions(except) {
  for (const card of grid.querySelectorAll('.card.acting')) {
    if (card === except) continue;
    card.classList.remove('acting');
    card.querySelector('.card-more').setAttribute('aria-expanded', false);
  }
}
document.addEventListener('pointerdown', e => closeActions(e.target.closest('.card')));

// A copy of a note, beside it: all that the note holds, whatever fields those are, under an id and
// a name of its own ("copy", then "copy 2", ...). The library shows it; it is not opened.
async function duplicate(doc) {
  const copy = { ...doc, id: newId(), updatedAt: Date.now() }; // storage writes it out in full, so the two share nothing
  try {
    const taken = new Set((await db.all()).map(d => d.name));
    copy.name = `${doc.name} copy`;
    for (let n = 2; taken.has(copy.name); n++) copy.name = `${doc.name} copy ${n}`;
    await db.put(copy);
  } catch {
    return notify('Could not duplicate the note.');
  }
  await showLibrary();
  [...grid.children].find(card => card.dataset.id === copy.id)?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
}

$('folder-delete').onclick = async () => {
  if (!folder) return;
  const count = (await db.all().catch(() => [])).filter(d => d.type !== 'folder' && d.folder === folder.id).length;
  const kept = count ? ` Its ${plural(count, 'note')} will not be deleted: ${count === 1 ? 'it goes' : 'they go'} back to Unfiled.` : '';
  if (!confirm(`Delete the folder "${folder.name}"?${kept}`)) return;
  await db.del(folder.id).catch(() => notify('Could not delete the folder.'));
  folder = null;
  showLibrary();
};

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
  search.value = ''; // a search would be looking in the new, empty folder
  leaveSide();
  await showLibrary();
  folderName.focus(); // straight into naming it
  folderName.select();
};
$('side-new-folder').onclick = $('new-folder').onclick;

// A blank note is a notebook: real pages of the paper chosen in the dialog (notebook.js), kept as
// pages and not as HTML (pages.js). It starts with one page, and is made where the library is.
$('new-notebook').onclick = async () => {
  const chosen = await askNotebook();
  if (!chosen) return;
  const doc = { id: newId(), name: chosen.name, html: '', strokes: [], updatedAt: Date.now(), pages: [{ h: paperHeight(chosen.paper) }], paper: chosen.paper };
  if (folder) doc.folder = folder.id;
  try {
    await db.put(doc);
  } catch {
    return notify('Could not create the notebook.');
  }
  openDoc(doc.id);
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
  if (androidPost) return androidPost({ type: 'save', name, text }); // the Android app, likewise
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
  // A paged note (pages.js): its pages and paper, and no HTML of its own. Any other may have gaps.
  const items = cleanItems(d.items);
  if (items.length) note.items = items;
  const pages = cleanPages(d.pages), gaps = cleanGaps(d.gaps);
  if (pages) Object.assign(note, { html: '', pages }, d.paper ? { paper: cleanPaper(d.paper) } : {});
  else if (gaps) note.gaps = gaps;
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

// An HTML file becomes a note as it is. A PDF becomes a paged note (pages.js), each of its pages a
// picture: pdfimport.js, which is only loaded, with the PDF reader behind it, when a PDF comes.
// What to call a file being imported, and which folder it goes in: asked each time, with the file's
// own name and the folder now shown there already, so that keeping them takes one tap. Resolves to
// { name, folder } (folder: an id, or '' for Unfiled), or to null if the file is to be left out.
const renameDialog = $('rename'), renameInput = $('rn-name'), renameFolder = $('rn-folder');
function askName(name, folders, into) {
  renameInput.value = name;
  renameFolder.replaceChildren(new Option('Unfiled', ''), ...folders.map(f => new Option(f.name, f.id)));
  renameFolder.value = into;
  renameDialog.returnValue = '';
  renameDialog.showModal();
  return new Promise(resolve => {
    renameDialog.onclose = () => resolve(renameDialog.returnValue === 'ok' ? { name: renameInput.value.trim() || name, folder: renameFolder.value } : null);
  });
}
$('rn-skip').onclick = () => renameDialog.close();
renameDialog.addEventListener('click', e => { if (e.target === renameDialog) renameDialog.close(); }); // a tap outside it

async function importFiles(fileList) {
  const files = [...fileList].filter(f => /\.(html?|pdf)$/i.test(f.name));
  if (!files.length) return notify('Only .html and .pdf files can be imported.');
  const failed = [];
  let into = folder?.id ?? ''; // the folder shown when the import began (a PDF takes a while), then whichever was last chosen
  const folders = (await db.all().catch(() => [])).filter(d => d.type === 'folder').sort(byName);
  let last, slow = false;
  for (const file of files) {
    try {
      const pdf = /\.pdf$/i.test(file.name);
      $('rn-skip').textContent = files.length > 1 ? 'Skip' : 'Cancel';
      const asked = await askName(file.name.replace(/\.(html?|pdf)$/i, ''), folders, into);
      if (asked === null) continue; // left out
      const { name } = asked;
      into = asked.folder; // the next file of this import starts from this choice
      const doc = {
        id: newId(),
        name,
        html: pdf ? '' : await file.text(), // ponytail: assumes UTF-8; sniff <meta charset> if legacy encodings matter
        strokes: [],
        updatedAt: Date.now(),
      };
      if (pdf) {
        slow = true;
        const { pdfPages } = await import('./pdfimport.js');
        doc.pages = await pdfPages(file, (n, of) => notify(`Importing ${file.name}: page ${n} of ${of}`));
      }
      if (into) doc.folder = into; // imported into a folder: it belongs there
      await db.put(doc); // only now, whole: a PDF that fails part way leaves nothing behind
      last = doc;
    } catch (error) {
      failed.push(error?.name === 'PasswordException' ? `${file.name} (it has a password)` : file.name);
    }
  }
  if (failed.length) notify(`Could not import: ${failed.join(', ')}`);
  else if (slow) message.hidden = true; // the last "Importing ..."
  if (!last && !failed.length) return; // every one was left out
  if (current) return; // a note was opened meanwhile: what was imported is in the library
  if (files.length === 1 && last) return openDoc(last.id);
  search.value = ''; // or a search could hide what was just imported
  if (last?.folder && folder?.id !== last.folder) folder = folders.find(f => f.id === last.folder) ?? folder; // show where it went
  else if (last && !last.folder) folder = null;
  showLibrary();
}

$('import-btn').onclick = () => fileInput.click();
importTile.onclick = () => $('new-notebook').click(); // "Create" makes a notebook, the usual new note
const addNoteFly = flyout($('add-note-wrap'), $('add-note'));
$('add-note').onclick = addNoteFly.toggle;
for (const item of $('add-note-wrap').querySelectorAll('.flyout button')) item.addEventListener('click', () => addNoteFly.set(false));
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
// The toolbar floats over the top of the window, a sheet of glass with the note passing beneath it
// (style.css). So the sheet's resting place, at the start of the note, is below the toolbar. In
// full screen the tools are a rail beside the window, and nothing is in the way.
const toolbar = $('toolbar');
const restTop = () => MARGIN + (document.body.matches('.full, .tools-off') ? 0 : toolbar.offsetHeight); // .tools-off: the toolbar is put away

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
  const w = PAGE_WIDTH * zoom, h = pageHeight * zoom, vw = scroller.clientWidth, vh = scroller.clientHeight, top = restTop();
  return [
    w + GUTTER <= vw ? (vw - w) / 2 : Math.min(MARGIN, Math.max(vw - w - MARGIN, x)),
    h + top + MARGIN <= vh ? top : Math.min(top, Math.max(vh - h - MARGIN, y)),
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
  const top = restTop(), h = pageHeight * zoom + top + MARGIN, vh = scroller.clientHeight, length = Math.max(28, vh * vh / h);
  bar.hidden = h <= vh;
  bar.style.height = length + 'px';
  bar.style.transform = `translateY(${(top - pos[1]) / (h - vh) * (vh - length)}px)`;
  if (pagesOpen) thumbs.setCurrent(pageAt());
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
  place([0, restTop()]);
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
  layoutPages();
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
      const pinned = pinUnits(value, MIN_HEIGHT); // export.js: an export shows the same
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
  space.loaded(); // the Add space mode (space.js) finds the note's gaps in it
  measure();
});

// Make the sheet as tall as the open note is: a paged note, its pages; a file, what is in it. Also
// called when the note grows or shrinks while it is open (a page added, a gap opened or closed).
function measure() {
  if (current.pages) {
    setPageHeight(pagesHeight(current));
    return syncPages();
  }
  const doc = frame.contentDocument;
  frame.style.height = MIN_HEIGHT + 'px'; // a document never measures less than the frame it is in: so one that got shorter is measured in a short frame
  setPageHeight(Math.max(MIN_HEIGHT, doc.documentElement.scrollHeight, doc.body?.scrollHeight ?? 0));
}

/* ---------- Editor: ink, tools, saving ---------- */

const ink = createInk(svg, {
  surface: scroller, // fingers pan and pinch anywhere in the window, grey margin included
  scroller: { scrollBy: ({ left = 0, top = 0 }) => panBy(left, top) }, // ink.js scrolls through this; see the view section
  onChange(strokes, items) {
    current.strokes = strokes;
    if (items.length || current.items) current.items = items;
    itemsView.render(items);
    // A notebook always has a blank page ahead: ink on its last page brings the next one (pages.js).
    if (current.pages && needsPage(current, strokes, items)) {
      addPage(current, undefined, frame.contentDocument);
      measure();
    }
    space.refresh(); // what can be removed in the Add space mode depends on where the ink is
    if (pagesOpen) thumbs.refresh();
    touch();
    refreshHistory();
    lasso.changed(); // undo, redo and the rest let go of what the lasso holds
  },
  onZoom: pinchMove, // two-finger pinch and pan
  onZoomEnd: pinchEnd,
  onDoubleTap: () => toggleEraser(),
  onTap: pt => { if (tool === 'text') textAt(pt); else if (tool === 'lasso') lasso.tapAt(pt); }, // a finger's tap
  onErase() { // eraser option "auto-deselect": go back to the previous tool once something was erased
    if (autoDeselect() && tool === 'eraser') choose(beforeEraser);
  },
});

// The lasso (lasso.js): circle some ink, then move it, resize it, recolour it or delete it. Its bar
// offers the colours of the pen panel, and keeps to the note's window, clear of the toolbar over its top.
const lassoBar = $('lasso-bar');
lassoBar.prepend(...[...document.querySelectorAll('#pen-colors [data-color]')].map(swatch => swatch.cloneNode(true)));
// The text boxes and pictures (items.js): ink.js keeps them, with the strokes, in its history; this draws them.
const itemsView = createItems($('items'), {
  change(from, to) { // a text box was made (from null), edited, or emptied (to null)
    const list = ink.getItems().map(it => (it === from ? to : it)).filter(Boolean);
    ink.replace(ink.getStrokes(), from ? list : [...list, to]);
  },
});
const lasso = createLasso(svg, ink, lassoBar, () => {
  const box = scroller.getBoundingClientRect();
  return [box.left, box.top + restTop() - MARGIN, box.right, box.bottom];
}, itemsView);
// The faint shadow of the Apple Pencil while it hovers (ghost.js); the settings flyout turns it off.
const ghost = createGhost(scroller);
// "Add space": a blank page put into a paged note, a gap opened in a file (space.js).
const space = createSpace({ button: $('space-btn'), mover, frame, ink, note: () => current, resize: measure });

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
  laser: { name: 'Laser', tool: 'laser', size: 4, opacity: 1 }, // for pointing: its line fades and is never part of the note
};
const STABILITY = 3; // a new pen's: how far its ink trails the tip to steady the line, 0 (not at all) to 10
const MAX_PENS = 12; // the full-screen rail has to hold every one of them
const FIRST_PENS = [['pen', '#111111'], ['pen', '#ffffff'], ['pen', '#ff1744'], ['flow', '#1c7ed6'], ['glow', '#ffea00'], ['highlighter', '#ffea00']];
const newPen = (type, color) => ({ id: newId(), type, color, size: PEN_TYPES[type].size, opacity: PEN_TYPES[type].opacity, stability: STABILITY });
const within1 = (n, low, high) => Math.min(high, Math.max(low, n));
// A saved pen's stability. 0 is a real setting, so this is not `|| STABILITY`; a pen saved before pens had one gets the usual.
const stabilityOf = p => { const n = Number(p.stability ?? STABILITY); return n >= 0 ? Math.min(10, n) : STABILITY; };

// The saved pens, or the starting set. What comes out of storage is checked: only pens that can be drawn with.
function readPens() {
  let list;
  try { list = JSON.parse(localStorage.getItem('pens')); } catch { /* storage blocked, or not JSON */ }
  const saved = (Array.isArray(list) ? list : [])
    .filter(p => p && PEN_TYPES[p.type] && typeof p.id === 'string' && p.id !== 'eraser' && p.id !== 'hand' && /^#[0-9a-f]{6}$/i.test(p.color))
    .slice(0, MAX_PENS)
    .map(p => ({ id: p.id, type: p.type, color: p.color, size: within1(+p.size || 3, 1, 12), opacity: within1(+p.opacity || 1, 0.1, 1), stability: stabilityOf(p) }));
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

// A pen as a picture, standing tip up, 24 wide and 64 tall. Its tip and band take the pen's colour
// (--c on the button, through style.css). The shading that makes it round, and the metal, are
// gradients kept once in index.html (#pen-barrel, #pen-metal, #pen-shade): a part is drawn in its
// colour and then once more in the shade, which is light down one side and dark down the other.
const shaded = (shape, cls) => `<${shape} class="${cls}"/><${shape} fill="url(#pen-shade)"/>`;
const PEN_TIPS = {
  // a fine cone with a metal point
  pen: shaded('path d="M12 2.6 17 18H7z"', 'tip') + '<path d="M12 .8 13.3 5.4h-2.6z" fill="url(#pen-metal)"/>',
  // a fountain pen's nib, slit and breather hole, on a collar of the pen's colour
  flow: '<path class="nib" d="M12 .6c2.9 4.5 5 9.9 4.6 17.4H7.4C7 10.5 9.1 5.1 12 .6z" fill="url(#pen-metal)"/>' +
    '<path class="slit" d="M12 4.4V13"/><circle class="slit" cx="12" cy="13.8" r=".9"/>',
  // the cone again, alight
  glow: '<g class="lit">' + shaded('path d="M12 2.6 17 18H7z"', 'tip') + '</g><path class="spark" d="M4.2 3.4v4M2.2 5.4h4M20.4 8.6v3M18.9 10.1h3"/>',
  // a chisel
  highlighter: shaded('path d="M7 18V8.4l10-5V18z"', 'tip'),
  // a metal nozzle, and the dot of light it throws
  laser: '<path d="M7.6 18v-6.4l1.9-2.8h5l1.9 2.8V18z" fill="url(#pen-metal)"/><g class="lit"><circle class="tip" cx="12" cy="4" r="2.7"/></g>',
};
function penPicture(type) {
  const wide = type === 'highlighter'; // a highlighter is a stouter pen
  const x = wide ? 4.5 : 6, w = wide ? 15 : 12;
  const part = (y, h, rest) => `rect x="${x}" y="${y}" width="${w}" height="${h}" ${rest}`;
  return `<svg viewBox="0 0 24 64" aria-hidden="true">${PEN_TIPS[type]}` +
    (type === 'flow' ? shaded(part(18, 4.4, 'rx=".5"'), 'band') : `<${part(18, 3.6, 'rx=".6" fill="url(#pen-metal)"')}/>`) +
    `<${part(21.6, 44, 'rx="2" fill="url(#pen-barrel)" class="barrel"')}/>` +
    (type === 'flow' ? `<${part(24.6, 1.4, 'fill="url(#pen-metal)"')}/>` : shaded(part(25.4, 3.4, ''), 'band')) +
    '</svg>';
}

const penBox = $('pens'), addWrap = $('add-wrap');
// `fresh`: the id of a pen just added, which rises into its place.
function renderPens(fresh) {
  penBox.replaceChildren(...pens.map((pen, i) => {
    const btn = document.createElement('button');
    const name = PEN_TYPES[pen.type].name;
    btn.type = 'button';
    btn.className = pen.id === fresh ? 'pen new' : 'pen';
    btn.dataset.tool = pen.id;
    btn.title = `${name}${i < 9 ? ` (${i + 1})` : ''}. Tap again for its settings`;
    btn.setAttribute('aria-label', `${name} ${i + 1}`);
    btn.setAttribute('aria-pressed', pen.id === tool);
    btn.style.setProperty('--c', pen.color);
    btn.innerHTML = penPicture(pen.type); // fixed markup from penPicture; the colour goes in through --c
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

// The text tool: a tap on the page makes a box and the keyboard comes up; a tap on text edits it
// (items.js does the typing). Tapped again while it is the tool, a flyout sets the size of the letters.
const textFly = flyout($('text-wrap'), document.querySelector('[data-tool="text"]'));
const textRange = $('text-range');
let textSize = 28;
try {
  const saved = Number(localStorage.getItem('textSize'));
  if (saved >= TEXT_SIZES[0] && saved <= 96) textSize = saved;
} catch { /* storage blocked */ }
function setTextSize(n) {
  textSize = n;
  textRange.value = n;
  $('text-sample').style.fontSize = `${Math.round(10 + n / 3)}px`; // a picture of the size, not to scale
}
textRange.oninput = () => {
  setTextSize(Number(textRange.value));
  try { localStorage.setItem('textSize', textSize); } catch { /* lasts for this visit only */ }
};
setTextSize(textSize);

function textAt(pt) {
  const box = itemsView.hit(ink.getItems(), pt, 'text');
  // The keyboard covers the lower part of the window: bring the place to be typed at up into the upper part first.
  const [, top] = origin(), y = top + pos[1] + (box ? box.y : pt[1]) * zoom;
  if (y > top + scroller.clientHeight * 0.45) place([pos[0], pos[1] - (y - top - scroller.clientHeight * 0.3)], true);
  itemsView.start(box ?? null, pt, { size: textSize, color: penOf(inkPen)?.color ?? '#111111' });
}
// With a stylus the text tool is a handler like the lasso's: a touch that stays put is a tap.
{
  let from = null, moved = false;
  ink.setHandler('text', {
    down: pt => { from = pt; moved = false; },
    move: pt => { if (Math.hypot(pt[0] - from[0], pt[1] - from[1]) > 10) moved = true; },
    up: () => { if (!moved) textAt(from); },
    cancel: () => {},
  });
}

// Hand the pen's own settings to the ink layer.
function usePen(pen) {
  ink.setTool(PEN_TYPES[pen.type].tool);
  ink.setColor(pen.color);
  ink.setSize(pen.size);
  ink.setOpacity(pen.opacity);
  ink.setStability(pen.stability);
}

let inkPen = ''; // the pen last used: text takes its colour
let previousTool = ''; // the tool before this one, for the Pencil's "last tool"
// Make `value` the tool: 'eraser', 'hand', 'lasso', 'text' or a pen's id.
function choose(value) {
  const pen = penOf(value);
  if (!pen && !['eraser', 'hand', 'lasso', 'text'].includes(value)) return;
  if (value !== 'lasso') lasso.clear(); // what the lasso held is let go with it
  if (value === 'eraser' && tool !== 'eraser') beforeEraser = tool;
  if (value !== tool && tool) previousTool = tool;
  if (value !== tool) showPanel(false);
  tool = value;
  autoBtn.hidden = value !== 'eraser';
  if (value !== 'eraser') eraserFly.set(false);
  if (value !== 'text') textFly.set(false);
  if (pen) {
    inkPen = pen.id;
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
const stabilityRange = $('pen-stability');

function fillPanel(pen) {
  $('pen-type').textContent = PEN_TYPES[pen.type].name;
  sizeRange.value = pen.size;
  $('pen-size-out').textContent = pen.size;
  opacityRange.value = Math.round(pen.opacity * 100);
  $('pen-opacity-out').textContent = `${opacityRange.value}%`;
  opacityRange.parentElement.hidden = pen.type === 'laser'; // a laser's line fades by itself: it has no opacity to set
  stabilityRange.value = pen.stability;
  $('pen-stability-out').textContent = pen.stability;
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
stabilityRange.oninput = () => editPen({ stability: Number(stabilityRange.value) });
customColor.oninput = () => editPen({ color: customColor.value });
// The colours chosen with the colour picker, the latest first: they come back as swatches after it.
const RECENT = 5;
let recent = [];
try { recent = JSON.parse(localStorage.getItem('recentColors')).filter(c => /^#[0-9a-f]{6}$/i.test(c)).slice(0, RECENT); } catch { /* none yet, or storage blocked */ }
function showRecent() {
  for (const old of panel.querySelectorAll('.recent')) old.remove();
  $('pen-colors').append(...recent.map(color => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'icon-btn swatch recent';
    btn.dataset.color = color;
    btn.style.setProperty('--c', color);
    btn.title = btn.ariaLabel = `Recent colour ${color}`;
    return btn;
  }));
}
customColor.onchange = () => { // the picker was closed: this is a colour to keep
  const color = customColor.value.toLowerCase();
  recent = [color, ...recent.filter(c => c !== color)].slice(0, RECENT);
  try { localStorage.setItem('recentColors', JSON.stringify(recent)); } catch { /* lasts for this visit only */ }
  showRecent();
  fillPanel(penOf(tool));
};
showRecent();
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
  const pen = newPen(type, { highlighter: '#ffea00', laser: '#ff1744' }[type] ?? penOf(tool)?.color ?? '#111111');
  pens.push(pen);
  renderPens(pen.id);
  choose(pen.id);
  showPanel(true);
});

toolbar.addEventListener('click', e => {
  const value = e.target.closest('button')?.dataset.tool;
  if (!value) return;
  if (value !== tool) return choose(value);
  // Already the tool: the tap is for its settings.
  if (value === 'eraser') eraserFly.toggle();
  else if (value === 'text') textFly.toggle();
  else showPanel(panel.hidden);
});
undoBtn.onclick = () => ink.undo();
redoBtn.onclick = () => ink.redo();

// Flip between the eraser and the tool used before it. Bound to a finger double-tap on the page:
// Apple Pencil's own double-tap (on its barrel) is only given to native apps, never to web pages.
const toggleEraser = () => choose(tool === 'eraser' ? beforeEraser : 'eraser');

// The iPad app (ios/) passes on what a web page is never told: a double-tap or a squeeze on the
// Apple Pencil itself. It arrives as a 'pencil' event on the window; in a browser it never fires.
// What each does is the user's choice (the settings flyout); the choices are kept on this device.
const PENCIL_ACTIONS = { eraser: 'Switch to the eraser', undo: 'Undo', redo: 'Redo', previous: 'Go back to the last tool', lasso: 'Lasso', hand: 'Hand', none: 'Nothing' };
const pencilChoice = { tap: 'eraser', squeeze: 'undo' }; // as it comes out of the box
for (const [which, select] of [['tap', $('pencil-tap')], ['squeeze', $('pencil-squeeze')]]) {
  select.replaceChildren(...Object.entries(PENCIL_ACTIONS).map(([value, name]) => new Option(name, value)));
  try { pencilChoice[which] = localStorage.getItem(`pencil-${which}`) ?? pencilChoice[which]; } catch { /* storage blocked */ }
  if (!(pencilChoice[which] in PENCIL_ACTIONS)) pencilChoice[which] = which === 'tap' ? 'eraser' : 'undo'; // a saved choice this version does not offer
  select.value = pencilChoice[which];
  select.onchange = () => {
    pencilChoice[which] = select.value;
    try { localStorage.setItem(`pencil-${which}`, select.value); } catch { /* lasts for this visit only */ }
  };
}
// A tool that is chosen again goes back: lasso, hand and the eraser each come and go.
const toggleTool = name => choose(tool === name ? (previousTool && previousTool !== name ? previousTool : pens[0].id) : name);
function pencilDo(action) {
  if (action === 'eraser') toggleEraser();
  else if (action === 'undo') ink.undo();
  else if (action === 'redo') ink.redo();
  else if (action === 'previous') { if (previousTool) choose(previousTool); }
  else if (action === 'lasso' || action === 'hand') toggleTool(action);
}
addEventListener('pencil', e => {
  if (current && (e.detail === 'tap' || e.detail === 'squeeze')) pencilDo(pencilChoice[e.detail]);
});
option($('ghost-btn'), 'penShadow', on => {
  ghost.enable(on);
  $('ghost-btn').textContent = on ? 'On' : 'Off';
}, true);
const settingsFly = flyout($('settings-wrap'), $('settings-btn'));
$('settings-btn').onclick = settingsFly.toggle;

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

// Mark the open note as changed and save it once the writing has paused. A save writes the whole
// note, every page picture of a PDF with it, and the page stops while that is copied: so it waits
// for a pause, never lands under a stroke being drawn, and is made sure of when the app is left.
const SAVE_AFTER = 2000;
function touch() {
  current.updatedAt = Date.now();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(autosave, SAVE_AFTER);
}

function autosave() {
  if (ink.busy()) saveTimer = setTimeout(autosave, SAVE_AFTER);
  else save();
}

function save() {
  clearTimeout(saveTimer);
  saveTimer = 0;
  return db.put(current).catch(() => notify('Could not save your changes.'));
}

// Save now if a save is pending.
const flush = () => {
  itemsView.finish(); // text still being typed is part of the note
  return saveTimer ? save() : undefined;
};
addEventListener('pagehide', flush);
document.addEventListener('visibilitychange', () => { if (document.hidden) flush(); }); // the app went to the background

async function openDoc(id) {
  const doc = await db.get(id).catch(() => null);
  if (!doc) return notify('That note could not be opened.');
  current = doc;
  pagesStale = true;
  document.body.classList.add('editing'); // must be visible before fitZoom() measures the scroller
  nameInput.value = doc.name;
  space.set(false);
  setPageHeight(doc.pages ? pagesHeight(doc) : MIN_HEIGHT); // a file: reset before load so the last note's height can't inflate the measurement
  frame.srcdoc = noteHtml(doc);
  const paper = doc.pages && cleanPaper(doc.paper).color, dark = paper && (parseInt(paper.slice(1, 3), 16) * 0.3 + parseInt(paper.slice(3, 5), 16) * 0.59 + parseInt(paper.slice(5, 7), 16) * 0.11) < 110;
  ghost.dark(!!dark); // a shadow on black paper is a light one
  const items = cleanItems(doc.items);
  ink.load(doc.strokes || [], items);
  itemsView.render(items);
  refreshHistory();
  lastFit = fitZoom();
  resetZoom(Math.min(1, lastFit));
  showPages();
}

async function closeDoc() {
  await flush();
  lasso.clear();
  current = null;
  frame.srcdoc = ''; // drop the document; also guarantees a reload if the same note is reopened
  showPages();
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

/* ---------- Pages ---------- */

// The column of pages (thumbs.js) beside a notebook or a PDF; an imported HTML file has no pages.
// What it asks for is done here, since it changes the note, its ink and the frame.
const pagesBtn = $('pages-btn'), pagesPanel = $('pages-panel');
let pagesOpen = false;   // the column is showing
let pagesStale = true;   // its pictures are of another note, or of pages that have changed
const thumbs = createThumbs({
  panel: pagesPanel, list: $('pages-list'), menu: $('page-menu'),
  note: () => current,
  strokes: () => current?.strokes ?? [],
  items: () => current?.items ?? [],
  go: i => place([pos[0], restTop() - pageTops(current)[i] * zoom], true),
  act: pageAct,
});
let pagesWanted = false; // the button is on
option(pagesBtn, 'pagesOpen', on => { pagesWanted = on; showPages(); });

// The page in the middle of what can be seen.
function pageAt() {
  const tops = pageTops(current), y = ((scroller.clientHeight + restTop()) / 2 - pos[1]) / zoom;
  let i = 0;
  while (i < tops.length - 2 && y >= tops[i + 1]) i++;
  return i;
}
// Below the toolbar, or at the top where the toolbar is a rail or put away.
function layoutPages() {
  pagesPanel.style.top = `${document.body.matches('.full, .tools-off') ? 10 : toolbar.offsetHeight + 8}px`;
}
function showPages() {
  const paged = !!current?.pages;
  pagesBtn.hidden = !paged;
  pagesOpen = paged && pagesWanted;
  pagesPanel.hidden = !pagesOpen;
  if (!pagesOpen) return thumbs.closeMenu();
  layoutPages();
  syncPages();
  thumbs.setCurrent(pageAt());
}
// The column shows the note's pages as they are: made again when it is opened, or the pages are not the ones it has.
function syncPages() {
  if (!current?.pages || !pagesOpen) return;
  if (pagesStale || thumbs.count() !== current.pages.length) {
    pagesStale = false;
    thumbs.build();
    thumbs.setCurrent(pageAt());
  }
}

function pageAct(what, i, extra) {
  const n = current.pages.length, order = [...Array(n).keys()];
  if (what === 'paper') {
    const page = current.pages[i];
    for (const [key, value] of Object.entries(extra)) { if (value) page[key] = value; else delete page[key]; }
    frame.contentDocument.body.children[i].setAttribute('style', pageStyle(page, current.paper));
    touch();
    return thumbs.refresh();
  }
  if (what === 'add') {
    const top = pageTops(current)[i + 1], page = addPage(current, i + 1, frame.contentDocument);
    ink.shift(top, page.h); // the ink below moves down with what it was written on; also saves
    measure();
    space.refresh();
    return thumbs.refresh();
  }
  if (what === 'duplicate') order.splice(i + 1, 0, i);
  else if (what === 'move') order.splice(extra, 0, order.splice(i, 1)[0]);
  else if (what === 'remove') {
    const page = current.pages[i];
    if ((page.img || inkedPages(current, ink.getStrokes(), ink.getItems())[i]) && !confirm(`Delete page ${i + 1}? Its ink goes with it, and undo cannot bring it back.`)) return;
    order.splice(i, 1);
  }
  restructure(order);
}

// The pages in a new order, doubled or fewer (pages.js, rearrange). The note's ink moves with them.
// The undo history is dropped: it is of pages that are no longer where they were.
function restructure(order) {
  const r = rearrange(current, ink.getStrokes(), ink.getItems(), order);
  const body = frame.contentDocument.body, shown = [...body.children];
  current.pages = r.pages;
  body.replaceChildren(...order.map((p, j) => (order.indexOf(p) === j ? shown[p] : shown[p].cloneNode(true))));
  lasso.clear();
  ink.load(r.strokes, r.items);
  itemsView.render(r.items);
  current.strokes = ink.getStrokes();
  if (current.items || r.items.length) current.items = ink.getItems();
  if (needsPage(current, current.strokes, r.items)) addPage(current, undefined, frame.contentDocument); // a notebook keeps a blank page ahead
  refreshHistory();
  measure();
  space.refresh();
  touch();
  thumbs.build();
  thumbs.setCurrent(pageAt());
}

/* ---------- Pictures ---------- */

// A picture from Photos or Files, or pasted: put in the middle of what can be seen, and held by the lasso,
// which moves it, resizes it (its corners) and deletes it.
const imageInput = $('image-input');
$('image-btn').onclick = () => imageInput.click();
imageInput.onchange = () => {
  const [file] = imageInput.files;
  imageInput.value = ''; // lets the same picture be picked again
  if (file) addImage(file);
};
async function addImage(file) {
  if (!current) return;
  let made;
  try {
    made = await readImage(file);
  } catch {
    return notify('That picture could not be opened.');
  }
  const x = within1((scroller.clientWidth / 2 - pos[0]) / zoom - made.w / 2, 0, Math.max(0, PAGE_WIDTH - made.w));
  const y = within1(((scroller.clientHeight + restTop()) / 2 - pos[1]) / zoom - made.h / 2, 0, Math.max(0, pageHeight - made.h));
  const item = { type: 'image', x: Math.round(x), y: Math.round(y), w: made.w, h: made.h, src: made.src };
  ink.replace(ink.getStrokes(), [...ink.getItems(), item]);
  choose('lasso');
  lasso.selectItems([item]);
}
document.addEventListener('paste', e => {
  if (!current || e.target.closest?.('input, textarea')) return;
  const file = [...(e.clipboardData?.files ?? [])].find(f => f.type.startsWith('image/'));
  if (file) {
    e.preventDefault();
    addImage(file);
  }
});

/* ---------- Export ---------- */

// The open note with its ink, as a PDF. export.js makes one document of the two. The iPad app is
// handed it, makes the file and offers it to be shared (ios/App/Exporter.swift), and says how that
// went in an 'export' event. A browser prints it: its print dialog can save a PDF.
const exportBtn = $('export-btn'), shellExport = window.webkit?.messageHandlers?.export;
exportBtn.onclick = async () => {
  exportBtn.disabled = true;
  notify('Preparing the PDF…');
  await new Promise(done => setTimeout(done, 50)); // let that be seen first: a long note takes a moment
  let waiting = false;
  try {
    const { html, pages } = exportDoc(current, current.strokes || [], { document: frame.contentDocument, height: pageHeight, screen: MIN_HEIGHT });
    if (shellExport) {
      shellExport.postMessage({ name: current.name, html, pages });
      waiting = true; // for the app's answer
    } else if (androidPost) {
      androidPost({ type: 'print', name: current.name, html }); // Android's print dialog can save a PDF
      message.hidden = true;
    } else {
      await printDoc(html);
      message.hidden = true;
    }
  } catch {
    notify('The note could not be exported.');
  }
  exportBtn.disabled = waiting;
};
addEventListener('export', e => {
  exportBtn.disabled = false;
  notify(e.detail?.ok ? 'The PDF is ready.' : `The PDF could not be made${e.detail?.message ? `: ${e.detail.message}` : ''}.`);
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
  const atStart = pos[1] >= restTop(); // at the note's first line: it stays there, wherever that now is (below the toolbar, or at the top beside the rail)
  document.body.classList.toggle('full', on);
  fullBtn.setAttribute('aria-pressed', on);
  if (on && !isIOS && !document.fullscreenElement) document.documentElement.requestFullscreen?.()?.catch(() => {});
  if (!on && document.fullscreenElement) document.exitFullscreen();
  refit();
  if (current && atStart) place([pos[0], restTop()]);
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

// The small arrow at the toolbar's edge puts the tools away and brings them back (body.tools-off in
// style.css). Only the user does this, and the device remembers it.
const toolsBtn = $('tools-toggle');
option(toolsBtn, 'toolsOff', off => {
  const atStart = pos[1] >= restTop(); // at the note's first line: it stays there, wherever that now is
  document.body.classList.toggle('tools-off', off);
  toolsBtn.title = off ? 'Show the toolbar' : 'Hide the toolbar';
  toolsBtn.setAttribute('aria-label', toolsBtn.title);
  if (off) { // nothing that hangs from the toolbar stays behind
    showPanel(false);
    eraserFly.set(false);
    addFly.set(false);
  }
  refit();
  if (current && atStart) place([pos[0], restTop()]);
});

/* ---------- Screen recording (the iPad app only) ---------- */

// A page cannot record the screen; the iPad app can (ios/App/Recorder.swift). The page asks it to
// start and stop, and is told how it went by 'recorder' events on the window. The video is the
// 16:9 window; these controls sit outside it (style.css, #rec-bar).
const shellRecorder = window.webkit?.messageHandlers?.recorder;
if (shellRecorder) {
  const recBtn = $('rec-btn'), recPause = $('rec-pause'), recTime = $('rec-time'), recQuality = $('rec-quality');
  const recEnhance = $('rec-enhance'), recBar = $('rec-bar');
  const recCount = $('rec-count'), recCheck = $('rec-check'), recWaves = $('rec-waves'), recCam = $('rec-cam'), recShape = $('rec-shape');

  // The bar changes shape: put away it is a dot in the corner, and its buttons come and go with the
  // recording. morph() makes any such change one movement. The change itself is made at once; the
  // bar is then shown going from the place and width it had to the ones it now has.
  //
  // Only `left` and `width` move, as plain lengths, and the bar is placed without any transform
  // (style.css). An earlier version centred the bar with a transform and moved it with another
  // property on top: on the iPad the centring was dropped for as long as the movement ran, so the
  // bar opened half its width too far right and then jumped back.
  let moving = null;
  const still = matchMedia('(prefers-reduced-motion: reduce)');
  function morph(change) {
    const from = recBar.getBoundingClientRect(); // read first: mid-movement, this is where it has got to
    moving?.cancel();
    recBar.classList.remove('moving');
    change();
    const to = recBar.getBoundingClientRect();
    if (!from.width || !to.width || still.matches || (from.width === to.width && from.left === to.left)) return;
    recBar.classList.add('moving'); // style.css: it is where and as wide as the movement says; nothing spills; on the way to the corner the buttons stay until it is there
    const mine = moving = recBar.animate(
      [{ left: `${from.left}px`, width: `${from.width}px` }, { left: `${to.left}px`, width: `${to.width}px` }],
      { duration: 480, easing: 'cubic-bezier(.3, 1.12, .36, 1)', fill: 'forwards' }, // quick off the mark, a touch past, and settle
    );
    // It ends on the very place the stylesheet then gives it, so letting go of it shows nothing.
    mine.onfinish = () => {
      recBar.classList.remove('moving');
      mine.cancel();
      if (moving === mine) moving = null;
    };
  }

  // Put away, the bar is a dot in the corner (with the clock, while recording): style.css, #rec-bar.min.
  option($('rec-min'), 'recMin', away => {
    morph(() => recBar.classList.toggle('min', away));
    $('rec-min').title = away ? 'Show the recording bar' : 'Put the recording bar away in the corner';
    $('rec-min').setAttribute('aria-label', $('rec-min').title);
  });
  // Enhance: the voice with the background noise taken out. It needs the microphone, so it is out of
  // reach without it; and so is the mic check, whose picture then goes from the bar.
  const micOn = option($('rec-mic'), 'recMic', on => morph(() => {
    recEnhance.disabled = !on || document.body.classList.contains('recording');
    recCheck.disabled = !on;
  }), true);
  const enhanceOn = option(recEnhance, 'recEnhance');
  const countOn = option($('rec-count-btn'), 'recCount', undefined, true); // 3, 2, 1 before a recording starts
  // 'idle', 'recording' or 'paused'. The clock counts recorded time only: `done` ms from before the
  // last pause, plus the time since `since` while it runs.
  let state = 'idle', done = 0, since = 0, ticker = 0;
  document.body.classList.add('can-record');

  try { recQuality.value = localStorage.getItem('recQuality') ?? recQuality.value; } catch { /* storage blocked */ }
  if (recQuality.selectedIndex < 0) recQuality.value = 'standard'; // a saved value this version does not offer
  recQuality.onchange = () => {
    try { localStorage.setItem('recQuality', recQuality.value); } catch { /* lasts for this visit only */ }
  };

  const showTime = () => {
    const s = Math.floor((done + (state === 'recording' ? Date.now() - since : 0)) / 1000);
    recTime.textContent = `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
  };
  function showState(next) {
    if (state === 'recording') done += Date.now() - since; // the stretch that just ended
    if (next === 'idle' || state === 'idle') done = 0;     // over, or a new recording
    state = next;
    since = Date.now();
    const on = state !== 'idle';
    morph(() => { // the bar's buttons change with this (style.css)
      document.body.classList.toggle('recording', on);
      document.body.classList.toggle('paused', state === 'paused');
      $('rec-label').textContent = on ? 'Stop' : 'Record';
      recPause.textContent = state === 'paused' ? 'Resume' : 'Pause';
    });
    recBtn.setAttribute('aria-pressed', on);
    recPause.setAttribute('aria-pressed', state === 'paused');
    // Fixed for the length of a recording: its settings, and the 16:9 window it is a picture of.
    $('rec-mic').disabled = recQuality.disabled = wideBtn.disabled = on;
    recEnhance.disabled = on || !micOn();
    clearInterval(ticker);
    if (state === 'recording') ticker = setInterval(showTime, 1000);
    showTime();
  }

  // Each button waits for the app's answer: starting asks the user's permission, stopping finishes the file.
  const ask = () => {
    recBtn.disabled = recPause.disabled = true;
    shellRecorder.postMessage(state === 'idle'
      ? { action: 'start', quality: recQuality.value, microphone: micOn(), enhance: micOn() && enhanceOn(), title: nameInput.value, wide: document.body.classList.contains('wide') }
      : { action: 'stop' });
  };

  // The countdown: 3, 2, 1 in the middle of the note, and only then is the app asked to record. So
  // the video does not begin with a hand leaving the screen, and the countdown is never in it.
  // Record, which reads Cancel meanwhile, calls it off; so does leaving the note.
  let counting = 0, left = 0; // the countdown's timer while one runs, and the seconds still to go
  function endCount() {
    clearInterval(counting);
    counting = 0;
    recCount.hidden = true;
    morph(() => { $('rec-label').textContent = 'Record'; });
  }
  function count() {
    if (!document.body.classList.contains('editing')) return endCount();
    if (!left) {
      endCount();
      return ask();
    }
    // Over the note's window, wherever that is just now (measured: it moves with full screen, 16:9 and the way the iPad is held).
    const box = scroller.getBoundingClientRect();
    Object.assign(recCount.style, { left: `${box.left}px`, top: `${box.top}px`, width: `${box.width}px`, height: `${box.height}px` });
    // A new element each second, so that each numeral comes and goes afresh (style.css).
    recCount.replaceChildren(Object.assign(document.createElement('span'), { textContent: left-- }));
    recCount.hidden = false;
  }
  recBtn.onclick = () => {
    if (counting) return endCount();
    if (state !== 'idle' || !countOn()) return ask();
    left = 3;
    morph(() => { $('rec-label').textContent = 'Cancel'; });
    count();
    counting = setInterval(count, 1000);
  };
  recPause.onclick = () => {
    recBtn.disabled = recPause.disabled = true;
    shellRecorder.postMessage({ action: state === 'paused' ? 'resume' : 'pause' });
  };
  addEventListener('recorder', e => {
    recBtn.disabled = recPause.disabled = false;
    const next = ['recording', 'paused'].includes(e.detail?.state) ? e.detail.state : 'idle';
    if (next !== state) showState(next); // the app may also speak up mid-recording, with nothing changed
    if (e.detail?.message) notify(e.detail.message);
    if (state === 'idle') askVideos(); // there may be a new one
  });

  // Mic check: a small moving picture, in the bar, of what the microphone hears, as it would be
  // recorded (through Enhance, if that is on). The app does the listening (Recorder.swift) and
  // sends 'mic' events: about twenty levels a second, each from 0 (silence) to 1.
  // It is never remembered: the microphone comes on because the user has just asked, not because
  // of a setting from another day.
  const BARS = 12; // each 3px wide and 2px apart: the picture's 58px (style.css)
  const levels = []; // the last few heard, the newest last
  function drawWaves() {
    const c = recWaves.getContext('2d'), k = recWaves.width / 58, h = recWaves.height; // k: the picture's dots to a px
    c.clearRect(0, 0, recWaves.width, h);
    c.fillStyle = getComputedStyle(recWaves).color;
    c.beginPath();
    for (let i = 0; i < BARS; i++) {
      const level = levels[levels.length - BARS + i] || 0; // what has not been heard yet is silence
      const tall = Math.max(3 * k, Math.min(1, level) * h);
      c.roundRect(i * 5 * k, (h - tall) / 2, 3 * k, tall, 1.5 * k);
    }
    c.fill();
  }
  function setCheck(on) {
    recCheck.setAttribute('aria-pressed', on);
    morph(() => recBar.classList.toggle('check', on));
  }
  recCheck.onclick = () => setCheck(recCheck.getAttribute('aria-pressed') !== 'true');
  // The app listens exactly while the picture is in sight: switched on, the microphone not switched
  // off, the bar there and not put away. Whatever changes that (or Enhance, which changes what is
  // heard) shows as a class or a button's state, so those are watched, and the app told of any change.
  const shellMic = window.webkit.messageHandlers.mic;
  let asked = '';
  function askMic() {
    const on = recWaves.offsetWidth > 0;
    const want = JSON.stringify(on ? { on, enhance: enhanceOn() } : { on });
    if (want === asked) return;
    asked = want;
    levels.length = 0; // a fresh start: nothing left over from before, or from the other way of listening
    drawWaves();
    shellMic?.postMessage(JSON.parse(want));
  }
  const watcher = new MutationObserver(askMic);
  watcher.observe(document.body, { attributeFilter: ['class'] });
  watcher.observe(recBar, { attributeFilter: ['class', 'aria-pressed', 'disabled'], subtree: true });
  askMic(); // not listening, to begin with: said, in case the page was loaded again while the app was
  addEventListener('mic', e => {
    if (e.detail?.on === false) { // the app cannot listen: the microphone refused, say
      setCheck(false);
      if (e.detail.message) notify(e.detail.message);
    } else if (recWaves.offsetWidth && Array.isArray(e.detail?.levels)) { // out of sight, there is nothing to draw on
      levels.push(...e.detail.levels.map(Number));
      levels.splice(0, levels.length - BARS);
      drawWaves();
    }
  });

  // The camera bubble: the front camera's picture, floating over the app, moved and resized with
  // the fingers. It is the app's own view (CameraBubble.swift; a page here cannot use the camera),
  // and the app remembers where it is and its shape. The page only asks, and shows what the app
  // answers in a 'camera' event: on or off (off with a message, if the camera was refused), and the shape.
  const shellCamera = window.webkit.messageHandlers.camera;
  const SHAPES = ['circle', 'square', 'wide', 'tall'];
  recCam.onclick = () => shellCamera?.postMessage({ on: recCam.getAttribute('aria-pressed') !== 'true', shape: recShape.dataset.shape });
  recShape.onclick = () => shellCamera?.postMessage({ on: true, shape: SHAPES[(SHAPES.indexOf(recShape.dataset.shape) + 1) % SHAPES.length] });
  addEventListener('camera', e => {
    const on = e.detail?.on === true;
    if (SHAPES.includes(e.detail?.shape)) recShape.dataset.shape = e.detail.shape; // also changed by a double tap on the bubble
    recCam.setAttribute('aria-pressed', on);
    morph(() => recBar.classList.toggle('cam', on));
    if (e.detail?.message) notify(e.detail.message);
  });
  shellCamera?.postMessage({ on: false }); // off, to begin with; the answer says which shape it has
}

/* ---------- Keyboard ---------- */

const TOOL_KEYS = { e: 'eraser', v: 'hand', l: 'lasso', t: 'text' }; // and 1 to 9: the pens, in tray order
// The keys a browser scrolls with, as fractions of the window's height (the note is not a browser scroller: see the view section).
const SCROLL_KEYS = { pagedown: 0.9, ' ': 0.9, pageup: -0.9, arrowdown: 0.12, arrowup: -0.12 };

document.addEventListener('keydown', e => {
  if (!current || e.target.closest?.('input, textarea, select')) return; // typing a name or in a text box, or moving a slider
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
    place([pos[0], key === 'home' ? Infinity : -Infinity]); // place() brings either back to the note's first or last line
  }
});

// The iPad app hands over a file shared to it ("Open in EngiNote"): its name, and where to fetch it
// (ios/App/NoteViewController.swift). It is imported like a file chosen here, name prompt and all.
addEventListener('shared', async e => {
  try {
    if (e.detail.error) throw new Error(e.detail.error);
    importFiles([new File([await (await fetch(e.detail.url)).blob()], e.detail.name)]);
  } catch {
    notify(`Could not open ${e.detail?.name ?? 'that file'}.`);
  }
});
window.webkit?.messageHandlers?.shared?.postMessage({ ready: true }); // ready for any that were shared before the page was up

showLibrary();
askVideos();
