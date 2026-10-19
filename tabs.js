// tabs.js — the notes that are open at once, as a strip of tabs under the toolbar. This holds the list
// and draws it; app.js does the opening and the saving (openDoc, closeDoc), and keeps on each tab what
// is needed to come back to it: where the note was scrolled to, how far it was zoomed, its undo steps.
// Plain ES module.

export const MAX_TABS = 5; // each open note is a whole page picture to hold and to draw again on a switch
const LONG_PRESS = 600;    // ms: a tab held this long closes all the others

const ICONS = {
  notebook: '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 8h6M9 12h6"/></svg>',
  file: '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M7 3h7l5 5v13H7z"/><path d="M14 3v5h5"/></svg>',
};
const CLOSE = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M7 7l10 10M17 7L7 17"/></svg>';

/** `list`: the element the tabs are drawn in. `onOpen(tab)`, `onClose(tab)`, `onCloseOthers(tab)`: what a tap on a tab, on its cross, and a long press ask for. */
export function createTabs({ list, onOpen, onClose, onCloseOthers }) {
  const tabs = []; // { id, name, kind, view?, history?, stamp? }: the last three are app.js's
  let active = null, recording = null;

  function render() {
    list.replaceChildren(...tabs.map(tab => {
      const el = document.createElement('div');
      el.className = 'note-tab';
      el.dataset.id = tab.id;
      el.setAttribute('role', 'tab');
      el.setAttribute('aria-selected', tab === active);
      el.classList.toggle('on', tab === active);
      const open = document.createElement('button');
      open.type = 'button';
      open.className = 'note-tab-open';
      open.innerHTML = ICONS[tab.kind] ?? ICONS.file;
      if (tab.id === recording) open.insertAdjacentHTML('beforeend', '<i class="note-tab-rec" title="Recording"></i>');
      const name = document.createElement('span');
      name.textContent = tab.name; // a name is whatever was typed: never markup
      open.append(name);
      const close = document.createElement('button');
      close.type = 'button';
      close.className = 'note-tab-x';
      close.title = 'Close this tab';
      close.setAttribute('aria-label', `Close ${tab.name}`);
      close.innerHTML = CLOSE;
      el.append(open, close);
      return el;
    }));
  }

  const tabOf = e => { const el = e.target.closest('.note-tab'); return el && tabs.find(t => t.id === el.dataset.id); };
  let held = 0, longPressed = false, from = null;
  const letGo = () => { clearTimeout(held); held = 0; };
  list.addEventListener('pointerdown', e => {
    const tab = e.target.closest('.note-tab-open') && tabOf(e);
    longPressed = false;
    letGo();
    if (!tab || tabs.length < 2) return;
    from = [e.clientX, e.clientY];
    held = setTimeout(() => { longPressed = true; onCloseOthers(tab); }, LONG_PRESS);
  });
  list.addEventListener('pointermove', e => { if (held && Math.hypot(e.clientX - from[0], e.clientY - from[1]) > 8) letGo(); });
  for (const type of ['pointerup', 'pointercancel', 'pointerleave']) list.addEventListener(type, letGo);
  list.addEventListener('click', e => {
    const tab = tabOf(e);
    if (!tab || longPressed) return;
    if (e.target.closest('.note-tab-x')) onClose(tab);
    else if (e.target.closest('.note-tab-open')) onOpen(tab);
  });

  return {
    list: () => tabs.slice(),
    find: id => tabs.find(t => t.id === id),
    get active() { return active; },
    isFull: () => tabs.length >= MAX_TABS,
    add(tab) { tabs.push(tab); return tab; },
    /** Which tab is being written in (null: none, the library is showing). */
    activate(tab) { active = tab; render(); },
    remove(tab) {
      const i = tabs.indexOf(tab);
      if (i >= 0) tabs.splice(i, 1);
      if (active === tab) active = null;
      render();
    },
    keepOnly(tab) { tabs.splice(0, tabs.length, tab); render(); },
    clear() { tabs.length = 0; active = null; render(); },
    /** The id of the tab that was in front when a recording began, for its red dot (null: not recording). */
    recording(id) { recording = id; render(); },
    render,
  };
}
