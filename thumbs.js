// thumbs.js — the page navigator: a column of small pictures of a paged note's pages, beside the note.
// Tap one to go to that page; press and hold one, then drag it, to move it; its "more" button opens
// a menu (duplicate, add a page after it, delete, its own colour and template). Plain ES module.
// What changes the note is app.js's business: this file shows, and calls `act` with what was asked.
import { makeEl, boxOf } from './ink.js';
import { PAGE_WIDTH, TEMPLATES, pageTops, pagePaper, paperCss } from './pages.js';

const THUMB_W = 120;               // px: how wide a picture is
const K = THUMB_W / PAGE_WIDTH;    // page px to picture px
const MAX_STROKES = 800;           // drawn on one picture; more than can be told apart at this size
const HOLD = 350;                  // ms a thumbnail is held before it comes up to be dragged
const SLOP = 8;                    // px a held thumbnail may stray before it is taken for a scroll
const NS = 'http://www.w3.org/2000/svg';
const COLOURS = [['#ffffff', 'White'], ['#fbf2d8', 'Cream'], ['#e6efff', 'Blue'], ['#e5f5e8', 'Green'], ['#111111', 'Black']];
const NAMES = { plain: 'Plain', rule: 'Rule', grid: 'Grid', dot: 'Dot', cornell: 'Cornell', planner: 'Planner' };
const MORE = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="5" cy="12" r="1.2"/><circle cx="12" cy="12" r="1.2"/><circle cx="19" cy="12" r="1.2"/></svg>';

// `panel` holds `list`; `menu` is the box the "more" menu is made in. note() is the open note (it
// has `pages`), strokes() and items() what is drawn on it, go(i) takes the view to page i, and
// act(name, ...args) does what was asked: 'move' (from, to), 'duplicate' (i), 'remove' (i), 'add' (i),
// 'paper' (i, { bg?, tpl? }; a key given as null goes back to the notebook's).
export function createThumbs({ panel, list, menu, note, strokes, items, go, act }) {
  const sheets = [];     // page index -> the picture's box
  const shown = new Set(); // the pictures now in sight, which are the ones that are drawn
  let current = -1;
  let timer = 0;

  const seen = new IntersectionObserver(entries => {
    for (const e of entries) {
      if (e.isIntersecting) { shown.add(e.target); fill(e.target); } else shown.delete(e.target);
    }
  }, { root: list, rootMargin: '240px 0px' });

  // Draw page i: its paper, its picture if it is one, the items on it, the strokes on it.
  function fill(box) {
    const doc = note(), i = Number(box.dataset.i), page = doc?.pages[i];
    if (!page) return;
    const top = pageTops(doc)[i], bottom = top + page.h;
    const paper = document.createElement('div');
    paper.className = 'thumb-paper';
    paper.style.cssText = `height:${page.h}px;transform:scale(${K});${paperCss(pagePaper(doc.paper, page), 0.8 / K)}`;
    if (page.img) {
      const img = new Image();
      img.alt = '';
      img.src = page.img;
      paper.append(img);
    }
    for (const it of items()) {
      if (it.y >= bottom || it.y + it.h <= top) continue;
      const el = it.type === 'image' ? new Image() : document.createElement('div');
      if (it.type === 'image') el.src = it.src;
      else {
        el.textContent = it.text;
        el.style.cssText = `font:${it.size}px/1.3 -apple-system,system-ui,sans-serif;color:${it.color};white-space:pre-wrap;overflow-wrap:anywhere;`;
      }
      el.style.position = 'absolute';
      el.style.left = it.x + 'px';
      el.style.top = it.y - top + 'px';
      el.style.width = it.w + 'px';
      paper.append(el);
    }
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', `0 ${top} ${PAGE_WIDTH} ${page.h}`);
    svg.style.cssText = `position:absolute;left:0;top:0;width:${PAGE_WIDTH}px;height:${page.h}px;overflow:hidden`;
    let n = 0;
    for (const s of strokes()) {
      const b = boxOf(s);
      if (b[3] < top || b[1] >= bottom) continue;
      try { svg.append(makeEl(s)); } catch { /* a stroke that cannot be drawn is left out */ }
      if (++n >= MAX_STROKES) break;
    }
    paper.append(svg);
    box.replaceChildren(paper);
  }

  // Make the whole column again: for a note just opened, or one whose pages changed.
  function build() {
    seen.disconnect();
    shown.clear();
    sheets.length = 0;
    const doc = note();
    if (!doc?.pages) return list.replaceChildren();
    list.replaceChildren(...doc.pages.map((page, i) => {
      const item = document.createElement('div');
      item.className = 'thumb';
      item.dataset.i = i;
      item.setAttribute('role', 'listitem');
      item.innerHTML = `<div class="thumb-sheet"></div><span class="thumb-n">${i + 1}</span>` +
        `<button class="icon-btn thumb-more" type="button" title="This page" aria-label="Page ${i + 1} options">${MORE}</button>`;
      const box = item.firstElementChild;
      box.dataset.i = i;
      box.style.height = page.h * K + 'px';
      sheets.push(box);
      seen.observe(box);
      return item;
    }));
    current = -1;
  }

  // Draw again the pictures that are in sight (the note was written on), and leave the rest until they are.
  let later = 0;
  function refresh() {
    clearTimeout(later);
    later = setTimeout(() => { for (const box of shown) fill(box); }, 500);
  }

  function setCurrent(i) {
    if (i === current) return;
    current = i;
    list.querySelectorAll('.thumb').forEach((t, n) => t.classList.toggle('on', n === i));
    const t = list.children[i];
    if (!t || panel.hidden) return;
    const box = list.getBoundingClientRect(), at = t.getBoundingClientRect();
    if (at.top < box.top || at.bottom > box.bottom) list.scrollTop += at.top - box.top - (box.height - at.height) / 2;
  }

  // ---------- the menu ----------

  let menuFor = -1;
  function closeMenu() {
    menu.hidden = true;
    menuFor = -1;
  }
  function openMenu(i, button) {
    const doc = note(), page = doc.pages[i], n = doc.pages.length;
    menuFor = i;
    const row = (label, name, extra = '') => `<button class="btn-secondary${extra}" type="button" data-do="${name}">${label}</button>`;
    // Colour and template: only where the page is paper (a page of a PDF is a picture, and covers it).
    const paper = page.img ? '' :
      '<div class="menu-head">Page colour</div><div class="menu-swatches">' +
      `<button class="icon-btn chip" type="button" data-bg="" aria-pressed="${!page.bg}">Same</button>` +
      COLOURS.map(([c, name]) => `<button class="icon-btn swatch" type="button" data-bg="${c}" style="--c:${c}" title="${name}" aria-label="${name}" aria-pressed="${page.bg === c}"></button>`).join('') +
      '</div><div class="menu-head">Page template</div><div class="menu-swatches">' +
      `<button class="icon-btn chip" type="button" data-tpl="" aria-pressed="${!page.tpl}">Same</button>` +
      TEMPLATES.map(t => `<button class="icon-btn chip" type="button" data-tpl="${t}" aria-pressed="${page.tpl === t}">${NAMES[t]}</button>`).join('') + '</div>';
    menu.innerHTML = row('Duplicate page', 'duplicate') + row('Add a page after', 'add') +
      (i > 0 ? row('Move up', 'up') : '') + (i < n - 1 ? row('Move down', 'down') : '') +
      (n > 1 ? row('Delete page', 'remove', ' danger') : '') + paper;
    menu.hidden = false;
    // Beside the picture it belongs to, kept inside the editor.
    const home = menu.offsetParent.getBoundingClientRect(), at = button.getBoundingClientRect();
    menu.style.left = `${panel.getBoundingClientRect().right - home.left + 8}px`;
    menu.style.top = `${Math.max(8, Math.min(at.top - home.top, home.height - menu.offsetHeight - 8))}px`;
  }
  menu.addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b || menuFor < 0) return;
    const i = menuFor;
    if ('bg' in b.dataset || 'tpl' in b.dataset) {
      act('paper', i, 'bg' in b.dataset ? { bg: b.dataset.bg || null } : { tpl: b.dataset.tpl || null });
      return openMenu(i, list.children[i].querySelector('.thumb-more')); // shows the choice now made
    }
    closeMenu();
    const what = b.dataset.do;
    if (what === 'up') act('move', i, i - 1);
    else if (what === 'down') act('move', i, i + 1);
    else if (what) act(what, i);
  });
  document.addEventListener('pointerdown', e => { if (!menu.hidden && !menu.contains(e.target) && !e.target.closest('.thumb-more')) closeMenu(); });

  // ---------- taps, and moving a page ----------

  // A press that stays where it is for HOLD ms lifts that thumbnail; it is then dragged to where it
  // is to go, and a line shows the place. A touch that moves first is a scroll of the column, and is left alone.
  let hold = null;   // { id, i, x, y } a press that may become a drag
  let drag = null;   // { i, to, line }
  const gap = y => { // the place a thumbnail dropped at `y` would take: 0 to the number of pages
    const kids = [...list.children];
    let at = kids.length;
    for (let n = 0; n < kids.length; n++) {
      const b = kids[n].getBoundingClientRect();
      if (y < b.top + b.height / 2) { at = n; break; }
    }
    return at;
  };
  function lineAt(at) {
    const kids = [...list.children];
    if (!drag.line) {
      drag.line = document.createElement('div');
      drag.line.className = 'thumb-line';
      list.parentNode.append(drag.line);
    }
    const home = list.parentNode.getBoundingClientRect();
    const y = at < kids.length ? kids[at].getBoundingClientRect().top - 3 : kids[kids.length - 1].getBoundingClientRect().bottom + 3;
    drag.line.style.top = `${y - home.top}px`;
  }
  function endDrag() {
    clearTimeout(timer);
    hold = null;
    if (drag?.line) drag.line.remove();
    list.querySelectorAll('.lifted').forEach(t => t.classList.remove('lifted'));
    drag = null;
  }
  list.addEventListener('pointerdown', e => {
    const t = e.target.closest('.thumb');
    if (!t || e.target.closest('.thumb-more') || (e.button && e.button !== 0)) return;
    const i = [...list.children].indexOf(t);
    hold = { id: e.pointerId, i, x: e.clientX, y: e.clientY };
    timer = setTimeout(() => {
      if (!hold) return;
      drag = { i, to: i };
      t.classList.add('lifted');
      try { list.setPointerCapture(hold.id); } catch { /* the pointer is gone */ }
      lineAt(i);
    }, HOLD);
  });
  list.addEventListener('pointermove', e => {
    if (!hold || e.pointerId !== hold.id) return;
    if (!drag) {
      if (Math.hypot(e.clientX - hold.x, e.clientY - hold.y) > SLOP) { clearTimeout(timer); hold = null; } // it is a scroll
      return;
    }
    drag.to = gap(e.clientY);
    lineAt(drag.to);
    // Near the column's top or foot it scrolls, so that a far place can be reached.
    const box = list.getBoundingClientRect();
    if (e.clientY < box.top + 36) list.scrollTop -= 10;
    else if (e.clientY > box.bottom - 36) list.scrollTop += 10;
  });
  list.addEventListener('pointerup', e => {
    if (!hold || e.pointerId !== hold.id) return;
    const from = hold.i, dragged = drag, to = drag?.to;
    endDrag();
    if (!dragged) return go(from); // a tap
    const target = to > from ? to - 1 : to; // the gap counts the lifted picture too
    if (target !== from) act('move', from, target);
  });
  list.addEventListener('pointercancel', endDrag);
  // Once a thumbnail is lifted, a finger's move must drag it, not scroll the column.
  list.addEventListener('touchmove', e => { if (drag && e.cancelable) e.preventDefault(); }, { passive: false });
  list.addEventListener('click', e => {
    const more = e.target.closest('.thumb-more');
    if (!more) return;
    const i = [...list.children].indexOf(more.closest('.thumb'));
    if (menuFor === i) closeMenu();
    else openMenu(i, more);
  });

  return { build, refresh, setCurrent, closeMenu, count: () => sheets.length };
}
