// pages.js — what a note is shown as. Plain ES module; nothing here needs the app.
//
// Everything that shows a note (the editor's frame, a card's picture, an export) asks noteHtml(doc)
// for the document to show, and never reads doc.html itself. There are two kinds of note:
//
// A paged note (a blank notebook; a file imported page by page) is an ordinary note
// ({ id, name, html, strokes, updatedAt, folder? }) with two more fields, and no HTML of its own:
//
//   pages: [{ h }, { h, img }, ...]   One entry per page, top to bottom. `h` is the page's height in
//                                     page px (every page is PAGE_WIDTH wide). `img`, if there, is a
//                                     data:image/ URL drawn to fill the page; a page without one
//                                     shows the paper.
//   paper: { size, direction, template, color, line, spacing }   What a blank page looks like.
//   html:  ''                         Its document is made from the pages whenever it is wanted
//                                     (pagesHtml). Keeping it too would store every page's picture twice.
//
// An HTML note (an imported file) keeps the file in `html`, untouched, and may have gaps opened in it
// for more room to write:
//
//   gaps: [{ path, height, trim? }]   `path`: from <body> to the element the gap comes after, as a
//                                     list of child indexes (children that are elements, in the file
//                                     as imported). `height`: how far the gap moves everything below
//                                     it, in page px. `trim`: see spacerStyle().

export const PAGE_WIDTH = 900; // the width every note is laid out at; the same number as in app.js

/* ---------- Paged notes ---------- */

// Paper sizes: the long side over the short one. At a fixed width only the proportion matters.
export const SIZES = { A4: 297 / 210, Letter: 11 / 8.5, '16:9': 16 / 9, '4:3': 4 / 3 };
export const TEMPLATES = ['plain', 'rule', 'grid', 'dot'];
export const PAPER = { size: 'A4', direction: 'vertical', template: 'plain', color: '#ffffff', line: '#c8ccd6', spacing: 3 };
export const SPACING = [1, 8]; // the least and the most `spacing` may be
const spacingPx = spacing => Math.round(8 * (spacing + 1)); // 16 to 72 page px between lines; 3 is 32, about 7.5 mm on A4

const colour = (value, otherwise) => (typeof value === 'string' && /^#[0-9a-f]{6}$/i.test(value) ? value.toLowerCase() : otherwise);

/** A paper that can be drawn, whatever was handed in: anything missing or wrong becomes the default. */
export function cleanPaper(p) {
  p = p && typeof p === 'object' ? p : {};
  return {
    size: Object.hasOwn(SIZES, p.size) ? p.size : PAPER.size,
    direction: p.direction === 'horizontal' ? 'horizontal' : 'vertical',
    template: TEMPLATES.includes(p.template) ? p.template : PAPER.template,
    color: colour(p.color, PAPER.color),
    line: colour(p.line, PAPER.line),
    spacing: Math.min(SPACING[1], Math.max(SPACING[0], Number(p.spacing) || PAPER.spacing)),
  };
}

/** The pages of a note from outside (a backup file), in the shape above; null if they are not pages. */
export function cleanPages(list) {
  if (!Array.isArray(list) || !list.length) return null;
  const pages = [];
  for (const p of list) {
    if (!p || !Number.isFinite(p.h) || p.h <= 0) return null;
    pages.push(typeof p.img === 'string' && p.img.startsWith('data:image/') ? { h: p.h, img: p.img } : { h: p.h });
  }
  return pages;
}

/** How tall a page of this paper is, in page px. A4 upright: 1273. 16:9 on its side: 506. */
export function paperHeight(paper) {
  const { size, direction } = cleanPaper(paper);
  return Math.round(direction === 'horizontal' ? PAGE_WIDTH / SIZES[size] : PAGE_WIDTH * SIZES[size]);
}

/** Where each page starts, and where the last one ends: one more number than there are pages. */
export function pageTops(doc) {
  const tops = [0];
  for (const page of doc.pages) tops.push(tops[tops.length - 1] + page.h);
  return tops;
}

export const pagesHeight = doc => pageTops(doc)[doc.pages.length];

/** The paper as CSS declarations: its colour, and its lines, squares or dots drawn as a background.
    The pages of a note use this, and so does anything that shows a picture of the paper.
    `thick`: how many px wide the lines are. 1 on a page; more for a picture that is then shrunk,
    where a 1px line would all but vanish. */
export function paperCss(paper, thick = 1) {
  const { template, color, line, spacing } = cleanPaper(paper), s = spacingPx(spacing);
  const across = `linear-gradient(to bottom,transparent ${s - thick}px,${line} ${s - thick}px)`; // a line at the foot of every `s`
  const down = `linear-gradient(to right,transparent ${s - thick}px,${line} ${s - thick}px)`;
  const drawn = {
    plain: '',
    rule: `background-image:${across};background-size:100% ${s}px;`,
    // Squares and dots are centred across the page, so the part-squares at its two edges match.
    grid: `background-image:${across},${down};background-size:${s}px ${s}px;background-position:center top;`,
    dot: `background-image:radial-gradient(circle,${line} ${1.5 * thick}px,transparent ${2 * thick}px);background-size:${s}px ${s}px;background-position:center top;`,
  };
  return `background-color:${color};${drawn[template]}`;
}

const attr = text => text.replace(/[&<>"]/g, c => `&#${c.charCodeAt(0)};`);

/** One page as markup. */
export function pageHtml(page) {
  return `<div class="page" style="height:${Number(page.h)}px">${page.img ? `<img src="${attr(page.img)}" alt="">` : ''}</div>`;
}

/** A paged note as a document: its pages one under the other with nothing between them but a thin
    line, each exactly as tall as its `h`. No scripts. */
export function pagesHtml(doc) {
  return '<!doctype html><html><head><meta charset="utf-8"><style>' +
    'html,body{margin:0}' +
    'body{background:#9a9fab}' + // only seen past the last page, where a frame is taller than the note (a card's picture of a short one)
    `.page{position:relative;width:${PAGE_WIDTH}px;overflow:hidden;${paperCss(doc.paper)}}` +
    '.page img{display:block;width:100%;height:100%}' +
    // Where one page ends and the next begins. A middle grey: it shows on white paper and on black.
    '.page+.page::before{content:"";position:absolute;top:0;left:0;right:0;height:1px;background:#7f8696}' +
    '</style></head><body>' + doc.pages.map(pageHtml).join('') + '</body></html>';
}

/** Put a blank page into a note, before page `index` (left out: at the end). It is the size of the
    notebook's pages; after a page that is a picture, the size of that page. Returns the new page.
    `shown`: a document showing the note (the editor's frame). It is changed to match, in place:
    loading the note into the frame again would blank it for a moment. */
export function addPage(doc, index = doc.pages.length, shown) {
  const above = doc.pages[index - 1];
  const page = { h: above?.img ? above.h : paperHeight(doc.paper) };
  doc.pages.splice(index, 0, page);
  const before = shown?.body?.children[index];
  if (before) before.insertAdjacentHTML('beforebegin', pageHtml(page));
  else shown?.body?.insertAdjacentHTML('beforeend', pageHtml(page));
  return page;
}

/** Take page `index` out of a note. Returns the page. `shown`: as for addPage(). */
export function removePage(doc, index, shown) {
  const [page] = doc.pages.splice(index, 1);
  shown?.body?.children[index]?.remove();
  return page;
}

/** For each page, whether any of `strokes` is on it. A stroke is on every page from its highest
    point to its lowest.
    ponytail: reads every point of every stroke each time; keep a top and bottom with each stroke if
    a notebook of thousands of strokes ever makes this show. */
export function inkedPages(doc, strokes) {
  const tops = pageTops(doc), inked = doc.pages.map(() => false);
  for (const s of strokes) {
    let high = Infinity, low = -Infinity;
    for (const p of s.points) {
      if (p[1] < high) high = p[1];
      if (p[1] > low) low = p[1];
    }
    for (let i = 0; i < inked.length; i++) if (low >= tops[i] && high < tops[i + 1]) inked[i] = true;
  }
  return inked;
}

/** A notebook always has a blank page ahead: true when its last page is a blank one that has been
    written on. (A last page that is a picture, the end of an imported file, is the end.) */
export function needsPage(doc, strokes) {
  return !doc.pages[doc.pages.length - 1].img && inkedPages(doc, strokes)[doc.pages.length - 1];
}

/* ---------- Gaps in an HTML note ---------- */

// A gap is held open by an empty element, the spacer, put into the note's document after the
// element its path names. Spacers are told from the note's own elements by this attribute, whose
// value is the gap's place in doc.gaps.
export const GAP_MARK = 'data-enginote-gap';

/** An element's children, leaving out spacers: what a gap's path counts. */
export const kids = el => [...el.children].filter(c => !c.hasAttribute(GAP_MARK));

/** The gaps of a note from outside (a backup file), in the shape above; null if there are none. */
export function cleanGaps(list) {
  const gaps = (Array.isArray(list) ? list : [])
    .filter(g => g && Array.isArray(g.path) && g.path.length && g.path.length <= 64 && g.path.every(i => Number.isInteger(i) && i >= 0) &&
      Number.isFinite(g.height) && g.height > 0)
    .map(g => ({ path: [...g.path], height: g.height, ...(Number.isFinite(g.trim) && g.trim ? { trim: g.trim } : {}) }));
  return gaps.length ? gaps : null;
}

/** The spacer's style. It is `height` tall, less `trim`: putting anything between two blocks stops
    their margins sharing the same space, which by itself moves the lower one down by the smaller
    margin. The editor measures that when the gap is made (space.js) and keeps it as `trim`, so that
    what is below a gap moves by `height` exactly, here and wherever else the note is shown.
    The rest makes it a full-width row of nothing in whatever it is put into, with the note's own
    background showing through. */
export function spacerStyle(gap) {
  return 'display:block!important;box-sizing:border-box!important;flex:0 0 auto!important;grid-column:1/-1!important;float:none!important;' +
    `width:100%!important;height:${Math.max(0, gap.height - (gap.trim || 0))}px!important;min-height:0!important;max-height:none!important;` +
    'margin:0!important;padding:0!important;border:0!important;background:none!important;';
}

/** The document to show for a note: a paged note's pages; an HTML note's file, with its gaps opened.
    Gaps go in as text (the file is read, the spacers put in, and it is written out again), so a
    frame that cannot be reached into, like a card's, shows them too.
    ponytail: a file with gaps is shown as the browser writes it back out, which is the same page in
    all but odd corners (a <pre> that starts with an empty line loses it). Without gaps it is shown untouched. */
export function noteHtml(doc) {
  if (doc.pages) return pagesHtml(doc);
  if (!doc.gaps?.length) return doc.html;
  const file = new DOMParser().parseFromString(doc.html, 'text/html');
  // Every path is followed before anything is put in: a spacer must not shift what a later path counts.
  const places = doc.gaps.map(gap => gap.path.reduce((el, i) => el && el.children[i], file.body));
  places.forEach((after, i) => {
    if (!after || after === file.body) return; // a path that leads nowhere: that gap is left out
    const spacer = file.createElement('div');
    spacer.setAttribute(GAP_MARK, i);
    spacer.setAttribute('style', spacerStyle(doc.gaps[i]));
    after.after(spacer);
  });
  return (file.doctype ? new XMLSerializer().serializeToString(file.doctype) : '') + file.documentElement.outerHTML;
}
