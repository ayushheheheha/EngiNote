// browser.js — the page's side of the in-app browser (ios/App/BrowserPane.swift). The browser itself is a
// native view that the app lays over the note's window; this says whether it is open and exactly where,
// and keeps that right as the window changes. Plain ES module. In a browser (no app) it does nothing.
//
// The native view is above the whole page, so it must stay clear of what the page still needs: the toolbar and
// the tabs above it, the recording bar below it. Of what the page shows over the note, a menu or the recording
// countdown would be hidden behind it: while one is up the app steps the browser aside (`held`). The page's
// messages (a recording failed) are shown by the app over the foot of the browser (`say`).

const GAP = 6;    // px kept between the browser and the bars it stays clear of
const BELOW = 120; // px from the window's top within which a bar counts as being above it

/** `button`: opens and closes it. `shell`: the app's 'browser' message handler. `scroller`: the note's window.
 *  `bars`: what must stay visible above or below the browser. `holds`: elements whose being shown puts the browser aside. */
export function createBrowser({ button, shell, scroller, bars, holds, editor, tools }) {
  let on = false, sent = '', queued = 0;
  const body = document.body;

  /** The rectangle the browser fills, in page pixels; null while there is no room. */
  function rect() {
    const box = scroller.getBoundingClientRect();
    let top = box.top, bottom = box.bottom;
    for (const bar of bars) {
      const r = bar.getBoundingClientRect();
      if (!r.height || r.right <= box.left || r.left >= box.right) continue; // not there, or beside the window (the full-screen rail)
      if (r.top < box.top + BELOW) top = Math.max(top, r.bottom + GAP);
      else if (r.bottom > box.bottom - BELOW) bottom = Math.min(bottom, r.top - GAP);
    }
    const x = Math.round(box.left), y = Math.round(top), w = Math.round(box.width), h = Math.round(bottom - top);
    return w >= 100 && h >= 100 ? { x, y, w, h } : null;
  }

  const held = () => holds.some(el => !el.hidden) || editor.querySelector('[aria-expanded="true"]') !== null;

  function sync() {
    queued = 0;
    if (!on) return;
    if (!body.classList.contains('editing')) return close(); // the library is showing: the browser is not part of it
    const at = rect();
    if (!at) return close();
    const news = { on: true, ...at, held: held() };
    const text = JSON.stringify(news);
    if (text === sent) return;
    sent = text;
    shell.postMessage(news);
  }
  const later = () => { if (!queued) queued = requestAnimationFrame(sync); };

  const watch = new MutationObserver(later);
  const size = new ResizeObserver(later);

  function open() {
    on = true;
    sent = '';
    button.setAttribute('aria-pressed', true);
    watch.observe(body, { subtree: true, attributes: true, attributeFilter: ['class', 'hidden', 'aria-expanded'] });
    for (const el of [scroller, ...bars]) size.observe(el);
    addEventListener('resize', later);
    sync();
  }

  function close() {
    if (!on) return;
    on = false;
    sent = '';
    button.setAttribute('aria-pressed', false);
    watch.disconnect();
    size.disconnect();
    removeEventListener('resize', later);
    shell.postMessage({ on: false });
  }

  button.addEventListener('click', () => (on ? close() : open()));
  // Picking up a pen, the lasso, the calculator or a picture means going back to the note.
  tools.addEventListener('click', e => { if (on && e.target.closest('#pens, [data-tool], #calc-btn, #image-btn')) close(); }, true);
  // The app's own "Note" button on the browser's bar.
  addEventListener('browser', e => { if (e.detail?.on === false) close(); });

  return {
    /** Show a message of the page's over the browser, if it is open (the page's own is behind it). */
    say(text) { if (on) shell.postMessage({ toast: text }); },
  };
}
