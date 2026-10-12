// export.js — a note with its ink as one document, to be made into a PDF: the iPad app makes the
// file from it; a browser prints it, and its print dialog can save a PDF. Plain ES module.
import { makeEl, boxOf } from './ink.js';
import { noteHtml, pageTops, inkedPages, paperCss, pageStyle, PAGE_WIDTH } from './pages.js';
import { itemHtml } from './items.js';

const attr = text => text.replace(/[&<>"]/g, c => `&#${c.charCodeAt(0)};`);

/** A length of CSS with its viewport heights made px of a screen `screen` px tall (app.js,
    pinViewportUnits, says why). vmax is included because that screen is taller than the page is wide. */
export const pinUnits = (css, screen) => css.replace(/(-?\d*\.?\d+)[dsl]?v(?:h|b|max)\b/g, (_, n) => n * screen / 100 + 'px');

// Printing leaves backgrounds out unless told otherwise: a notebook's paper, a note's own colours.
const PRINT = '*{-webkit-print-color-adjust:exact!important;print-color-adjust:exact!important}';
// The iPad app lays the document out in a web view of this width; without this it would take the
// document for a desktop page, lay it out wider and shrink it.
const VIEWPORT = `<meta name="viewport" content="width=${PAGE_WIDTH}, initial-scale=1">`;

// The ink between `top` and `top + height` of the note, as an <svg> to lie over exactly that part of
// it. Each stroke is drawn by the engine's own code (ink.js), so it looks as it does in the editor.
function inkSvg(strokes, top, height, style) {
  let drawn = '';
  for (const s of strokes) {
    try { // a stroke that cannot be drawn (a note from a damaged backup) is left out, not fatal
      const box = boxOf(s), reach = 3 * s.size; // a glow's halo reaches past the line itself
      if (box[3] + reach >= top && box[1] - reach <= top + height) drawn += makeEl(s).outerHTML;
    } catch { /* skip it */ }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 ${top} ${PAGE_WIDTH} ${height}" style="position:absolute;overflow:hidden;${style}">${drawn}</svg>`;
}

// The text boxes and pictures that are on the stretch of the note between `top` and `top + height`, placed as they are there.
const itemsOn = (items = [], top, height) => items.filter(it => it.y < top + height && it.y + it.h > top).map(it => itemHtml(it, top)).join('');

// A paged note: a PDF page for each of its pages, each the page's own size, its ink over it.
function pagedDoc(doc, strokes) {
  const tops = pageTops(doc), inked = inkedPages(doc, strokes, doc.items);
  // A notebook keeps a blank page ready at its end: blank pages nobody wrote on are left off the end.
  let count = doc.pages.length;
  while (count > 1 && !doc.pages[count - 1].img && !inked[count - 1]) count--;
  const pages = doc.pages.slice(0, count).map(p => ({ ...p, h: Number(p.h) }));
  const sizes = [...new Set(pages.map(p => p.h))]; // a kind of printed page for each height there is
  return {
    pages: pages.map(p => p.h),
    html: `<!doctype html><html><head><meta charset="utf-8">${VIEWPORT}<title>${attr(doc.name)}</title><style>` +
      sizes.map((h, i) => `@page s${i}{size:${PAGE_WIDTH}px ${h}px;margin:0}`).join('') +
      `html,body{margin:0}${PRINT}` +
      `.page{position:relative;width:${PAGE_WIDTH}px;overflow:hidden;break-inside:avoid;${paperCss(doc.paper)}}` +
      '.page+.page{break-before:page}' +
      '.page img{display:block;width:100%;height:100%}' +
      '</style></head><body>' +
      pages.map((p, i) => `<div class="page" style="${pageStyle(p, doc.paper)};page:s${sizes.indexOf(p.h)}">` +
        `${p.img ? `<img src="${attr(p.img)}" alt="">` : ''}${itemsOn(doc.items, tops[i], p.h)}${inkSvg(strokes, tops[i], p.h, 'left:0;top:0;width:100%;height:100%')}</div>`).join('') +
      '</body></html>',
  };
}

// An HTML note: the file as the editor shows it, gaps and all, as one page the size of the whole
// note, so that nothing is laid out again and the ink stays on the words it was written on.
// ponytail: a PDF page may be 200 inches long at most (14400 pt: about 14400 px of note in the iPad
// app, 19200 in a browser's print). A longer note needs cutting into pages, at gaps between its blocks.
// ponytail: a browser prints with the file's `@media print` rules, which the editor does not show:
// in a file that has some, the ink may not sit where it was written. (The iPad app does not print.)
function fileDoc(doc, strokes, height, shown) {
  const file = new DOMParser().parseFromString(noteHtml(doc), 'text/html');
  // The file is not trusted, and whatever shows this document runs no scripts (the app's frame is
  // sandboxed, the iPad app's web view has JavaScript off). Even so, none are sent along. Nor is a
  // "go to another page" instruction, nor the file's own idea of how wide a screen is.
  for (const el of file.querySelectorAll('script, meta[http-equiv="refresh" i], meta[name="viewport" i]')) el.remove();
  for (const el of file.querySelectorAll('*')) {
    for (const { name } of [...el.attributes]) if (/^on/i.test(name)) el.removeAttribute(name);
  }
  // The editor shows viewport heights as px of a fixed screen; the same here, in the file's text.
  // ponytail: done on the text of each style sheet, so it would also change a "50vh" inside a
  // quoted string or a file name there.
  for (const el of file.querySelectorAll('style')) el.textContent = pinUnits(el.textContent, shown.screen);
  for (const el of file.querySelectorAll('[style]')) el.setAttribute('style', pinUnits(el.getAttribute('style'), shown.screen));

  file.title = doc.name;
  file.head.insertAdjacentHTML('afterbegin', VIEWPORT);
  // The page is exactly the note's size, as the editor's frame is, and nothing spills onto a second.
  file.head.insertAdjacentHTML('beforeend',
    `<style>@page{size:${PAGE_WIDTH}px ${height}px;margin:0}html{height:${height}px!important;overflow:hidden!important}${PRINT}</style>`);
  // The ink lies over the whole note from its top left corner. Put in <body>, it is placed from
  // the page's corner, unless the file's <body> or <html> is itself "positioned": then from that
  // one's corner, which is measured in the note as it is open and taken off again.
  // ponytail: a <body> that is transformed or filtered is the same kind of thing, and is not looked for.
  const live = shown.document?.body;
  const holder = live && [live, live.parentElement].find(el => getComputedStyle(el).position !== 'static');
  const box = holder?.getBoundingClientRect(), x = box ? box.left + holder.clientLeft : 0, y = box ? box.top + holder.clientTop : 0;
  file.body.insertAdjacentHTML('beforeend',
    `<div style="position:absolute;left:${-x}px;top:${-y}px;width:${PAGE_WIDTH}px;height:${height}px;overflow:hidden;pointer-events:none">${itemsOn(doc.items, 0, height)}</div>` +
    inkSvg(strokes, 0, height, `left:${-x}px;top:${-y}px;width:${PAGE_WIDTH}px;height:${height}px;margin:0;pointer-events:none`));
  return { pages: [height], html: '<!doctype html>' + file.documentElement.outerHTML };
}

/** The note `doc` with `strokes` drawn on it, as a document with no scripts: { html, pages }.
    `pages`: how tall each page of the PDF is to be, in px (they are all PAGE_WIDTH wide, and lie
    one under the other in the document). `shown`, for an HTML note: { document, height, screen }:
    the note as it is open in the editor, how tall it is there, and the screen height its viewport
    units are shown for. */
export function exportDoc(doc, strokes, shown) {
  return doc.pages ? pagedDoc(doc, strokes) : fileDoc(doc, strokes, shown.height, shown);
}

/** Print a document made by exportDoc(): in a frame of its own, out of sight, with the browser's
    print dialog. The frame runs no scripts (the document holds an imported file, which is not
    trusted): the print is asked for from out here. Resolves when the dialog has been asked for.
    ponytail: the frame stays, out of sight, until the next export: Safari shows its dialog after
    print() returns, so there is no moment that is surely late enough to take it away. */
export function printDoc(html) {
  document.getElementById('print-frame')?.remove();
  const frame = document.createElement('iframe');
  frame.id = 'print-frame'; // style.css keeps it out of sight
  frame.setAttribute('sandbox', 'allow-same-origin allow-modals'); // never allow-scripts
  frame.setAttribute('aria-hidden', 'true');
  frame.tabIndex = -1;
  return new Promise((resolve, reject) => {
    frame.onload = () => {
      try {
        frame.contentWindow.focus();
        frame.contentWindow.print();
        resolve();
      } catch (error) {
        reject(error);
      }
    };
    frame.srcdoc = html;
    document.body.append(frame);
  });
}
