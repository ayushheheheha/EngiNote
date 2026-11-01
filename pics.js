// pics.js — the pictures of a paged note's pages, kept apart from the note itself.
//
// A note that came from a PDF used to carry every page as a base64 picture inside its one record:
// 180 pages made a record of 100 MB or more, which was read whole by the library, written whole by
// every autosave and put whole into the editor's frame. Now the record holds only
//   doc.pdf     an id, under which this store keeps `${pdf}:pdf` (the PDF file as it came, if it came as one)
//               and, as they are made, `${pdf}:${n}` (page n as a JPEG, drawn 2x as wide as it is shown),
//               and `${pdf}:t${n}` (a small one, for the page column and the library's cards);
//   page.n      which page of that this page is (a page that is a picture has one; paper has not).
// A page is drawn from the PDF when it is first wanted, kept, and found again the next time. So a note
// opens in the time it takes to draw the pages in sight, however many it has, and an import only has to
// read how big each page is.
//
// Plain ES module. `store(mode, run)` is app.js's way into IndexedDB's "pics" store (keys are text).
import { PAGE_WIDTH } from './pages.js';

const FULL = 2 * PAGE_WIDTH;  // px wide: sharp at the usual zoom, soft past about 300%
const SMALL = 640;            // px wide: the page column and the cards
const QUALITY = { full: 0.85, small: 0.8 };
const MAX_AREA = 16e6;        // px in one picture: an iPad will not make a canvas much bigger, so a very long page is drawn less sharp
const tick = (ms = 0) => new Promise(done => setTimeout(done, ms));

export const newPicsId = () => 'p' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);

let lib;
// pdf.js does its reading in a Worker, and falls back to this page's own thread when its worker
// module is already loaded (that module puts itself in globalThis.pdfjsWorker). It is loaded here
// on purpose: the iPad app serves the page from enginote://app/, where a Worker may not start.
// ponytail: so a page is drawn on the page's own thread, one at a time, never while a stroke is being
// drawn. A worker would not stop the touch for a moment per page; try one if the app ever allows it.
export const pdfjs = async () => (lib ??= (await Promise.all([import('./pdfjs.min.js'), import('./pdfjs.worker.min.js')]))[0]);

/** `busy()`: true while the pen is down, when nothing should be drawn. */
export function createPics(store, busy = () => false) {
  // Kept as the bytes and their type, not as a Blob: every browser stores these (some cannot store a Blob), and Safari's
  // own idea of where to keep a Blob has been the cause of lost data before.
  const getRaw = k => store('readonly', s => s.get(k));
  const get = async k => { const r = await getRaw(k); return r ? new Blob([r.b], { type: r.t }) : undefined; };
  const put = async (k, blob) => { const r = { t: blob.type, b: await blob.arrayBuffer() }; return store('readwrite', s => s.put(r, k)); };
  const range = id => IDBKeyRange.bound(`${id}:`, `${id}:￿`);

  // ---------- the PDFs, opened when a page of one is wanted ----------

  const opened = new Map(); // pdf id -> Promise of pdf.js's document (null: this note has no file, its pictures are all there is)
  function pdfOf(id) {
    if (!opened.has(id)) {
      opened.set(id, (async () => {
        const file = await getRaw(`${id}:pdf`);
        if (!file) return null;
        const { getDocument } = await pdfjs();
        return getDocument({ data: file.b, useWasm: false }).promise;
      })().catch(() => null));
      while (opened.size > 2) { // two at a time: each one is the whole file in memory
        const [old] = opened.keys();
        opened.get(old).then(pdf => pdf?.destroy()).catch(() => {});
        opened.delete(old);
      }
    }
    return opened.get(id);
  }

  /** Page n of the PDF as a JPEG `width` px wide (null if there is no PDF, or the page cannot be drawn). */
  async function draw(id, n, width, quality) {
    try {
      const pdf = await pdfOf(id);
      if (!pdf) return null;
      const page = await pdf.getPage(n), size = page.getViewport({ scale: 1 }); // turned as the file says it is to be seen
      const viewport = page.getViewport({ scale: Math.min(width / size.width, Math.sqrt(MAX_AREA / (size.width * size.height))) });
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(viewport.width);
      canvas.height = Math.round(viewport.height);
      const context = canvas.getContext('2d');
      context.fillStyle = '#fff'; // a PDF page is white where nothing is drawn; a JPEG has no "nothing"
      context.fillRect(0, 0, canvas.width, canvas.height);
      await page.render({ canvas, canvasContext: context, viewport }).promise;
      const blob = await new Promise(done => canvas.toBlob(done, 'image/jpeg', quality));
      page.cleanup();
      canvas.width = canvas.height = 0; // Safari keeps a canvas's memory until it is collected: give it back now
      return blob;
    } catch {
      return null;
    }
  }

  // ---------- finding and making ----------

  // One page is drawn at a time, in the order asked for. `wanted()` is asked again when its turn comes:
  // a page the view has left since is skipped, so scrolling far never waits for the pages passed.
  let line = Promise.resolve();
  const inflight = new Map();
  function stored(k, make, wanted) {
    if (inflight.has(k)) return inflight.get(k);
    const job = get(k).catch(() => undefined).then(had => {
      if (had) return had;
      return (line = line.then(async () => {
        if (wanted && !wanted()) return null;
        while (busy()) await tick(150);
        if (wanted && !wanted()) return null;
        const blob = await make();
        if (blob) await put(k, blob).catch(() => {}); // not kept: drawn again next time
        await tick(8); // a breath: the app answers a touch between pages
        return blob;
      }, () => null));
    }).finally(() => inflight.delete(k));
    inflight.set(k, job);
    return job;
  }

  // Object URLs, kept for a while so that a page scrolled back to is not made again; the oldest are let go.
  const urls = { full: new Map(), small: new Map() }, KEEP = { full: 16, small: 120 };
  function urlOf(kind, k, blob) {
    const cache = urls[kind];
    let url = cache.get(k);
    if (url) cache.delete(k); else url = URL.createObjectURL(blob);
    cache.set(k, url);
    while (cache.size > KEEP[kind]) {
      const [old, oldUrl] = cache.entries().next().value;
      cache.delete(old);
      URL.revokeObjectURL(oldUrl);
    }
    return url;
  }

  const fullKey = (doc, n) => `${doc.pdf}:${n}`, smallKey = (doc, n) => `${doc.pdf}:t${n}`;
  const smallBlob = (doc, n, wanted) => stored(smallKey(doc, n), async () => {
    const big = await get(fullKey(doc, n)).catch(() => undefined); // the page is already drawn: shrink it
    return (big && await shrink(big, SMALL, QUALITY.small)) || draw(doc.pdf, n, SMALL, QUALITY.small);
  }, wanted);

  return {
    /** Page n of `doc` as an object URL for an <img> (null if it cannot be had). `wanted()`: still wanted, when its turn comes. */
    async full(doc, n, wanted) {
      const id = doc.pdf, k = fullKey(doc, n);
      const blob = await stored(k, () => draw(id, n, FULL, QUALITY.full), wanted);
      return blob ? urlOf('full', k, blob) : null;
    },
    /** The same, small. */
    async small(doc, n, wanted) {
      const blob = await smallBlob(doc, n, wanted);
      return blob ? urlOf('small', smallKey(doc, n), blob) : null;
    },
    /** The same, small, as a data: URL, for a frame that is not allowed to load an object URL (a card's, which is sandboxed). */
    async smallData(doc, n) {
      const blob = await smallBlob(doc, n);
      return blob ? dataUrl(blob) : null;
    },

    /** The PDF file `file` becomes the picture source of `id`. */
    keepFile: (id, file) => put(`${id}:pdf`, file),
    /** Put a page's picture in by hand (a note that came with its pictures: an old record, a backup). */
    keepPage: (id, n, blob) => put(`${id}:${n}`, blob),
    /** Let go of everything that belongs to `id` (the note was deleted). */
    async drop(id) {
      if (!id) return;
      opened.get(id)?.then(pdf => pdf?.destroy()).catch(() => {});
      opened.delete(id);
      await store('readwrite', s => s.delete(range(id))).catch(() => {});
    },
    /** A copy of everything that belongs to `from`, under `to`. */
    async copy(from, to) {
      const keys = await store('readonly', s => s.getAllKeys(range(from)));
      for (const k of keys) { const r = await getRaw(k); await store('readwrite', s => s.put(r, to + k.slice(from.length))); }
    },

    /** The pages of `doc` as data: URLs for a file that must carry them (an export, a backup): a copy of the
        pages with `img` set, `width` px wide. `progress(done, of)`. Draws from the PDF what has not been drawn yet. */
    async inline(doc, width, progress = () => {}) {
      const pages = [];
      let done = 0;
      for (const p of doc.pages) {
        progress(done++, doc.pages.length);
        if (!p.n) { pages.push(p); continue; }
        const { n, ...rest } = p;
        const big = await get(fullKey(doc, n)).catch(() => undefined);
        const blob = (big && (await shrink(big, width, 0.8))) || await draw(doc.pdf, n, width, 0.8) || big;
        pages.push(blob ? { ...rest, img: await dataUrl(blob) } : rest);
        await tick();
      }
      return { ...doc, pages };
    },

    /** `doc` as a backup holds it. A note that came from a PDF takes the PDF file as it is (`pdfFile`, a data: URL) and
        nothing is drawn; one whose pictures are all there is (no file kept) carries them in its pages. */
    async packed(doc, progress) {
      if (!doc.pdf) return doc;
      const file = await getRaw(`${doc.pdf}:pdf`);
      const { pdf, ...rest } = doc;
      if (!file) return { ...(await this.inline(doc, 1300, progress)), pdf: undefined };
      return { ...rest, pdfFile: await dataUrl(new Blob([file.b], { type: file.t })) };
    },
    /** The other way: a note from a backup with `pdfFile` keeps the file, and is given its own id. */
    async unpacked(doc) {
      if (typeof doc.pdfFile !== 'string') return;
      const file = fromDataUrl(doc.pdfFile);
      delete doc.pdfFile;
      if (!file) { doc.pages = doc.pages?.map(({ n, ...rest }) => rest); return; } // damaged: its pages show as paper
      doc.pdf = newPicsId();
      await put(`${doc.pdf}:pdf`, file);
    },

    /** A note that carries its pictures in its pages (`img`: an old record, a backup) hands them to this store
        and keeps only `n`. Returns whether it changed. */
    async absorb(doc) {
      if (!doc.pages?.some(p => typeof p.img === 'string')) return false;
      doc.pdf ??= newPicsId();
      for (let i = 0; i < doc.pages.length; i++) {
        const p = doc.pages[i];
        if (typeof p.img !== 'string') continue;
        const blob = fromDataUrl(p.img);
        delete p.img;
        if (!blob) continue; // damaged: the page shows as paper
        p.n = i + 1;
        await put(fullKey(doc, p.n), blob);
      }
      return true;
    },
  };
}

// ---------- pictures as data ----------

/** A Blob from a data: URL (null if it is not one). */
function fromDataUrl(url) {
  const at = url.indexOf(',');
  if (at < 0) return null;
  try {
    const bytes = atob(url.slice(at + 1)), data = new Uint8Array(bytes.length);
    for (let i = 0; i < bytes.length; i++) data[i] = bytes.charCodeAt(i);
    return new Blob([data], { type: /^data:([^;,]+)/.exec(url)?.[1] || 'image/jpeg' });
  } catch {
    return null;
  }
}

const dataUrl = blob => new Promise((resolve, reject) => {
  const reader = new FileReader();
  reader.onload = () => resolve(reader.result);
  reader.onerror = () => reject(reader.error);
  reader.readAsDataURL(blob);
});

/** `blob` (a picture) as a JPEG at most `width` px wide, or null if it cannot be read. */
async function shrink(blob, width, quality) {
  try {
    const bitmap = await createImageBitmap(blob);
    const scale = Math.min(1, width / bitmap.width);
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(bitmap.width * scale));
    canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    bitmap.close?.();
    const out = await new Promise(done => canvas.toBlob(done, 'image/jpeg', quality));
    canvas.width = canvas.height = 0;
    return out;
  } catch {
    return null;
  }
}
