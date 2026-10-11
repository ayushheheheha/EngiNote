// pdfimport.js — a PDF file as the pages of a paged note (pages.js): each page a picture.
// Loaded only when a PDF is imported (app.js), and it in turn loads pdf.js (Mozilla, Apache-2.0:
// pdfjs.min.js and pdfjs.worker.min.js beside this file, licence in pdfjs.LICENSE.txt) only then.
import { PAGE_WIDTH } from './pages.js';

// ponytail: a page is drawn 1800 px wide, twice the width it is shown at, and kept as a JPEG. That is
// sharp at the usual zoom and soft past about 300%. Sharper means drawing the page again from the
// PDF as the zoom changes, and so keeping the PDF itself with the note.
const SHARP_WIDTH = 2 * PAGE_WIDTH;
const QUALITY = 0.85;
const MAX_AREA = 16e6; // px in one picture: an iPad will not make a canvas much bigger, so a very long page is drawn less sharp

let lib;
// pdf.js does its reading in a Worker, and falls back to this page's own thread when its worker
// module is already loaded (that module puts itself in globalThis.pdfjsWorker). It is loaded here
// on purpose: the iPad app serves the page from enginote://app/, where a Worker may not start.
// ponytail: so a big PDF is read on the page's own thread, a page at a time, with a breath between pages.
const pdfjs = async () => (lib ??= (await Promise.all([import('./pdfjs.min.js'), import('./pdfjs.worker.min.js')]))[0]);

/** The pages of a PDF `file`, as a paged note keeps them: [{ h, img }, ...]. `progress(n, of)` is
    called as each page is begun. Rejects if the file cannot be read (broken, or it has a password:
    the error's name is then 'PasswordException'). */
export async function pdfPages(file, progress = () => {}) {
  const { getDocument } = await pdfjs();
  // ponytail: pdf.js's extra data is not shipped (decoders in WebAssembly, the fonts and character
  // maps for files that do not carry their own). A JPEG 2000 picture then comes out blank, and text
  // in a font the file leaves out is drawn in one of the device's. Add those folders if it shows.
  const task = getDocument({ data: await file.arrayBuffer(), useWasm: false });
  try {
    const pdf = await task.promise, pages = [];
    for (let n = 1; n <= pdf.numPages; n++) {
      progress(n, pdf.numPages);
      const page = await pdf.getPage(n), size = page.getViewport({ scale: 1 }); // turned as the file says it is to be seen
      const viewport = page.getViewport({ scale: Math.min(SHARP_WIDTH / size.width, Math.sqrt(MAX_AREA / (size.width * size.height))) });
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(viewport.width);
      canvas.height = Math.round(viewport.height);
      const context = canvas.getContext('2d');
      context.fillStyle = '#fff'; // a PDF page is white where nothing is drawn; a JPEG has no "nothing"
      context.fillRect(0, 0, canvas.width, canvas.height);
      await page.render({ canvas, canvasContext: context, viewport }).promise;
      pages.push({ h: Math.round(PAGE_WIDTH * size.height / size.width), img: canvas.toDataURL('image/jpeg', QUALITY) });
      page.cleanup();
      canvas.width = canvas.height = 0; // Safari keeps a canvas's memory until it is collected: give it back now
      await new Promise(done => setTimeout(done)); // let the app draw and answer a touch between pages
    }
    return pages;
  } finally {
    await task.destroy().catch(() => {});
  }
}
