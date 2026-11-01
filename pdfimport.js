// pdfimport.js — a PDF file as the pages of a paged note (pages.js): the file is kept with the note and
// only each page's size is read here, so an import takes about as long as the file takes to open, not
// the time to draw its pages. A page is drawn when it is first looked at (pics.js).
// Loaded only when a PDF is imported (app.js), and it in turn loads pdf.js (Mozilla, Apache-2.0:
// pdfjs.min.js and pdfjs.worker.min.js beside this file, licence in pdfjs.LICENSE.txt) only then.
import { PAGE_WIDTH } from './pages.js';
import { pdfjs, newPicsId } from './pics.js';

/** Keep `file` for the note `doc` (sets `doc.pdf`) and return its pages as a paged note holds them: [{ h, n }, ...].
    `progress(n, of)` is called as the pages are measured. Rejects if the file cannot be read (broken, or it has a
    password: the error's name is then 'PasswordException'). Nothing is kept unless the whole file reads. */
export async function importPdf(pics, doc, file, progress = () => {}) {
  const { getDocument } = await pdfjs();
  // ponytail: pdf.js's extra data is not shipped (decoders in WebAssembly, the fonts and character
  // maps for files that do not carry their own). A JPEG 2000 picture then comes out blank, and text
  // in a font the file leaves out is drawn in one of the device's. Add those folders if it shows.
  const task = getDocument({ data: await file.arrayBuffer(), useWasm: false });
  try {
    const pdf = await task.promise, pages = [];
    for (let n = 1; n <= pdf.numPages; n++) {
      if (n % 10 === 1) {
        progress(n, pdf.numPages);
        await new Promise(done => setTimeout(done)); // let the app draw between lots of pages
      }
      const page = await pdf.getPage(n), size = page.getViewport({ scale: 1 }); // turned as the file says it is to be seen
      pages.push({ h: Math.round(PAGE_WIDTH * size.height / size.width), n });
      page.cleanup();
    }
    const id = newPicsId();
    await pics.keepFile(id, file);
    doc.pdf = id;
    return pages;
  } finally {
    await task.destroy().catch(() => {});
  }
}
