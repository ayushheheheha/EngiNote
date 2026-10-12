// notebook.js — the "New notebook" dialog (#notebook in index.html): choose the paper, see it, create.
// Plain ES module. What a paper is, and how it is drawn, is in pages.js.
import { PAGE_WIDTH, cleanPaper, paperCss, paperHeight } from './pages.js';

const $ = id => document.getElementById(id);
const dialog = $('notebook'), title = $('nb-title'), sheet = $('nb-sheet'), picture = $('nb-page'), spacing = $('nb-spacing');
const custom = { color: $('nb-color'), line: $('nb-line') }; // "another colour": the device's own picker
let paper = cleanPaper();

// Show the dialog as `paper` now is: which choices are on, and the picture.
function show() {
  for (const group of dialog.querySelectorAll('[data-key]')) {
    const key = group.dataset.key, own = custom[key];
    let listed = false;
    for (const btn of group.querySelectorAll('[data-value]')) {
      const on = btn.dataset.value === paper[key];
      btn.setAttribute('aria-pressed', on);
      listed ||= on;
    }
    if (!own) continue;
    // A colour that is not one of the swatches shows on the "another colour" button.
    own.value = paper[key];
    own.parentElement.setAttribute('aria-pressed', !listed);
    own.parentElement.style.setProperty('--c', paper[key]);
  }
  spacing.value = paper.spacing;
  spacing.disabled = paper.template === 'plain' || paper.template === 'planner'; // nothing to space
  dialog.style.setProperty('--paper', paper.color); // the template tiles are drawn in the chosen colours (style.css)
  dialog.style.setProperty('--line', paper.line);
  // The picture is a page as it will be made: the same size and the same paper (paperCss), shrunk
  // as one piece to fit its box. Nothing about it moves, so a plain transform does the shrinking.
  // Only its lines are drawn thicker, to still be lines once shrunk.
  const height = paperHeight(paper), box = sheet.parentElement;
  const scale = Math.min((box.clientWidth - 32) / PAGE_WIDTH, (box.clientHeight - 32) / height);
  sheet.style.width = PAGE_WIDTH * scale + 'px';
  sheet.style.height = height * scale + 'px';
  picture.style.cssText = `width:${PAGE_WIDTH}px;height:${height}px;transform:scale(${scale});${paperCss(paper, 0.7 / scale)}`;
}

dialog.addEventListener('click', e => {
  if (e.target === dialog) return dialog.close(); // a tap outside it, on the dimmed library
  const btn = e.target.closest('[data-value]');
  if (!btn) return;
  paper[btn.closest('[data-key]').dataset.key] = btn.dataset.value;
  show();
});
for (const key in custom) custom[key].oninput = () => { paper[key] = custom[key].value; show(); };
spacing.oninput = () => { paper.spacing = Number(spacing.value); show(); };
$('nb-cancel').onclick = () => dialog.close();
addEventListener('resize', () => { if (dialog.open) show(); }); // the tablet was turned: the picture's box changed

/** Ask for a new notebook. Resolves to { name, paper }, or to null if the dialog was put away. */
export function askNotebook() {
  let last;
  try { last = JSON.parse(localStorage.getItem('paper')); } catch { /* storage blocked, or not JSON */ }
  paper = cleanPaper(last); // the paper chosen last time, or the default
  title.value = '';
  dialog.returnValue = '';
  dialog.showModal();
  show(); // once it is open: the picture is fitted to its box
  return new Promise(resolve => {
    // Create is the form's button, so it (and Enter in the title) closes the dialog with its value.
    // Cancel, Esc and a tap outside close it with none.
    dialog.onclose = () => {
      if (dialog.returnValue !== 'create') return resolve(null);
      try { localStorage.setItem('paper', JSON.stringify(paper)); } catch { /* lasts for this visit only */ }
      resolve({ name: title.value.trim() || 'Untitled notebook', paper: { ...paper } });
    };
  });
}
