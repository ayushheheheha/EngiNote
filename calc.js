// calc.js — the scientific calculator: a pane that floats over the note and works like a Casio
// fx-991ES Plus. Plain ES module; the sum is typed as one line of text (`1⌟3⁄4 + sin(30)`), shown
// the way a textbook writes it (stacked fractions, raised powers) and worked out in two kinds of number:
//  - an exact fraction (BigInt over BigInt) for anything that can be one: 1÷3 stays 1/3, 0.1+0.2 is
//    exactly 3/10, √(1/4) is 1/2, sin(30°) is 1/2. S⇔D turns such an answer into a decimal and back;
//  - a plain float for the rest (sin 20°, ln 5, π): shown to ten digits, as the Casio does.
// The sum has a cursor, as on the Casio: the ◀ ▶ keys move it, what is typed goes in at it, ⌫ takes out what is before it.
// Not done, on purpose: answers as √ or π forms (√2 is shown as 1.414213562), tapping the sum to put the cursor there.

const MATH = 'Math ERROR', SYNTAX = 'Syntax ERROR';
const fail = message => { throw new Error(message); };

/* ---------- Numbers: { n, d } (a fraction in lowest terms, d > 0) or a float ---------- */

const gcd = (a, b) => { a = a < 0n ? -a : a; b = b < 0n ? -b : b; while (b) [a, b] = [b, a % b]; return a; };
const abs = n => (n < 0n ? -n : n);
const digits = n => abs(n).toString().length;
export const isFraction = v => typeof v === 'object';
const toFloat = v => (isFraction(v) ? Number(v.n) / Number(v.d) : v);
// Too many digits to be worth keeping exact (the Casio gives up near ten, this is generous): a float from here on.
const frac = (n, d = 1n) => {
  if (d === 0n) fail(MATH);
  if (d < 0n) { n = -n; d = -d; }
  const g = gcd(n, d) || 1n;
  const v = { n: n / g, d: d / g };
  return digits(v.n) > 40 || digits(v.d) > 40 ? toFloat(v) : v;
};
const finite = x => (Number.isFinite(x) ? x : fail(MATH));
const both = (a, b) => isFraction(a) && isFraction(b);

const add = (a, b) => (both(a, b) ? frac(a.n * b.d + b.n * a.d, a.d * b.d) : finite(toFloat(a) + toFloat(b)));
const mul = (a, b) => (both(a, b) ? frac(a.n * b.n, a.d * b.d) : finite(toFloat(a) * toFloat(b)));
const neg = a => (isFraction(a) ? { n: -a.n, d: a.d } : -a);
const sub = (a, b) => add(a, neg(b));
const div = (a, b) => {
  if (toFloat(b) === 0) fail(MATH);
  return both(a, b) ? frac(a.n * b.d, a.d * b.n) : finite(toFloat(a) / toFloat(b));
};

// The whole-number k-th root of n >= 0, rounded down (Newton's way).
function root(n, k) {
  if (n < 2n) return n;
  let x = 1n << BigInt(Math.ceil(n.toString(2).length / Number(k)));
  for (;;) {
    const y = ((k - 1n) * x + n / x ** (k - 1n)) / k;
    if (y >= x) return x;
    x = y;
  }
}
// The k-th root of a fraction when it is exact (a fraction again), else a float.
function nthRoot(a, k) {
  if (isFraction(a)) {
    if (k === 2n && a.n < 0n) fail(MATH);
    const sign = a.n < 0n ? -1n : 1n, n = root(abs(a.n), k), d = root(a.d, k);
    if (n ** k === abs(a.n) && d ** k === a.d) return frac(sign * n, d);
  }
  const x = toFloat(a);
  return k === 2n ? (x < 0 ? fail(MATH) : Math.sqrt(x)) : Math.cbrt(x);
}

function pow(a, b) {
  if (both(a, b) && b.d === 1n && abs(b.n) <= 1000n && (digits(a.n) + digits(a.d)) * Number(abs(b.n)) <= 400) {
    if (b.n === 0n) return a.n === 0n ? fail(MATH) : { n: 1n, d: 1n };
    const e = abs(b.n), top = a.n ** e, bottom = a.d ** e;
    return b.n > 0n ? frac(top, bottom) : frac(bottom, top);
  }
  if (both(a, b) && (b.d === 2n || b.d === 3n)) return pow(nthRoot(a, b.d), frac(b.n)); // x^(1/2), x^(3/2), x^(2/3)…
  const x = toFloat(a), y = toFloat(b);
  if (x === 0 && y <= 0) fail(MATH);
  const r = Math.pow(x, y);
  return Number.isNaN(r) ? fail(MATH) : finite(r);
}

const factorial = a => {
  if (!isFraction(a) || a.d !== 1n || a.n < 0n || a.n > 69n) fail(MATH); // 69! is the largest the Casio gives
  let r = 1n;
  for (let i = 2n; i <= a.n; i++) r *= i;
  return frac(r);
};

/* ---------- Functions. Trig works in degrees or radians; what is exactly a half, a whole or nothing is made so ---------- */

const whole = (x, tol) => (Math.abs(x - Math.round(x)) < tol ? frac(BigInt(Math.round(x))) : x);
const half = x => (Math.abs(x * 2 - Math.round(x * 2)) < 1e-12 ? frac(BigInt(Math.round(x * 2)), 2n) : x);

function trig(name, a, deg) {
  const x = toFloat(a);
  if (name === 'asin' || name === 'acos') {
    if (Math.abs(x) > 1) fail(MATH);
    const r = name === 'asin' ? Math.asin(x) : Math.acos(x);
    return deg ? whole((r * 180) / Math.PI, 1e-9) : r;
  }
  if (name === 'atan') return deg ? whole((Math.atan(x) * 180) / Math.PI, 1e-9) : Math.atan(x);
  // Whole turns are dropped first, so that sin(390°) is as exact as sin(30°).
  const turn = deg && isFraction(a) ? toFloat(frac(a.n % (360n * a.d), a.d)) : x;
  const r = deg ? (turn * Math.PI) / 180 : turn;
  if (name === 'sin') return half(Math.sin(r));
  if (name === 'cos') return half(Math.cos(r));
  if (Math.abs(Math.cos(r)) < 1e-12) fail(MATH); // tan of a right angle
  return whole(Math.tan(r), 1e-12);
}

function logarithm(name, a) {
  const x = toFloat(a);
  if (!(x > 0)) fail(MATH);
  if (name === 'ln') return isFraction(a) && a.n === 1n && a.d === 1n ? frac(0n) : Math.log(x);
  const r = Math.round(Math.log10(x)); // an exact power of ten gives a whole number
  if (isFraction(a) && (r >= 0 ? a.d === 1n && a.n === 10n ** BigInt(r) : a.n === 1n && a.d === 10n ** BigInt(-r))) return frac(BigInt(r));
  return Math.log10(x);
}

const FUNCTIONS = {
  sin: (a, c) => trig('sin', a, c.deg), cos: (a, c) => trig('cos', a, c.deg), tan: (a, c) => trig('tan', a, c.deg),
  asin: (a, c) => trig('asin', a, c.deg), acos: (a, c) => trig('acos', a, c.deg), atan: (a, c) => trig('atan', a, c.deg),
  ln: a => logarithm('ln', a), log: a => logarithm('log', a),
  '√': a => nthRoot(a, 2n), '∛': a => nthRoot(a, 3n),
};

/* ---------- Reading the sum ---------- */

function number(text) {
  const [mantissa, exponent] = text.split('E'), [i, f = ''] = mantissa.split('.');
  let n = BigInt(i + f || '0'), d = 10n ** BigInt(f.length);
  if (exponent !== undefined) {
    const e = parseInt(exponent.replace('−', '-'), 10);
    if (Math.abs(e) > 300) fail(MATH);
    if (e >= 0) n *= 10n ** BigInt(e); else d *= 10n ** BigInt(-e);
  }
  return frac(n, d);
}

function tokenize(src) {
  const tokens = [];
  for (let i = 0; i < src.length;) {
    const rest = src.slice(i);
    let m;
    if ((m = /^(?:\d+\.?\d*|\.\d+)(?:E[+−-]?\d+)?/.exec(rest))) tokens.push({ k: 'num', v: number(m[0]) });
    else if ((m = /^(?:asin|acos|atan|sin|cos|tan|ln|log|√|∛)/.exec(rest))) tokens.push({ k: 'fn', v: m[0] });
    else if ((m = /^Ans/.exec(rest))) tokens.push({ k: 'ans' });
    else if ((m = /^[πe]/.exec(rest))) tokens.push({ k: 'const', v: m[0] });
    else if ((m = /^[-+−×÷*/^!()⁄⌟]/.exec(rest))) tokens.push({ k: 'op', v: { '-': '−', '*': '×', '/': '÷' }[m[0]] ?? m[0] });
    else if ((m = /^\s+/.exec(rest))) { /* skipped */ } else fail(SYNTAX);
    i += m[0].length;
  }
  return tokens;
}

/** The value of a sum. `ctx`: { ans, deg }. An empty sum is null; a sum that cannot be worked out throws an Error whose message is the Casio's. */
export function evaluate(src, ctx = {}) {
  const tokens = tokenize(src);
  if (!tokens.length) return null;
  const c = { ans: frac(0n), deg: true, ...ctx };
  let p = 0;
  const op = v => tokens[p]?.k === 'op' && tokens[p].v === v;

  // sum := product (+|− product)*; a product also goes on without a sign: 2π, 3(4+1), 2sin(30)
  const sum = () => {
    let a = product();
    for (;;) {
      if (op('+')) { p++; a = add(a, product()); } else if (op('−')) { p++; a = sub(a, product()); } else return a;
    }
  };
  const atomAhead = () => { const t = tokens[p]; return t && (t.k === 'num' || t.k === 'fn' || t.k === 'const' || t.k === 'ans' || (t.k === 'op' && t.v === '(')); };
  const product = () => {
    let a = unary();
    for (;;) {
      if (op('×')) { p++; a = mul(a, unary()); } else if (op('÷')) { p++; a = div(a, unary()); } else if (atomAhead()) a = mul(a, unary());
      else return a;
    }
  };
  // −2^2 is −(2^2), and 2^−1 is allowed: the sign is looser than the power but a power's exponent may carry one
  const unary = () => {
    if (op('−')) { p++; return neg(unary()); }
    if (op('+')) { p++; return unary(); }
    const base = postfix();
    if (op('^')) { p++; return pow(base, unary()); }
    return base;
  };
  const postfix = () => {
    let a = atom();
    while (op('!')) { p++; a = factorial(a); }
    return a;
  };
  const group = () => { // after "(": the sum inside; a bracket left open at the very end is closed for you
    const a = sum();
    if (op(')')) p++; else if (p < tokens.length) fail(SYNTAX);
    return a;
  };
  const wholeNumber = () => (tokens[p]?.k === 'num' ? tokens[p++].v : fail(SYNTAX));
  const atom = () => {
    const t = tokens[p++];
    if (!t) fail(SYNTAX);
    if (t.k === 'num') {
      if (op('⌟')) { // mixed number: 1⌟3⁄4
        p++;
        const n = wholeNumber();
        if (!op('⁄')) fail(SYNTAX);
        p++;
        return add(t.v, div(n, wholeNumber()));
      }
      if (op('⁄')) { p++; return div(t.v, wholeNumber()); }
      return t.v;
    }
    if (t.k === 'const') return t.v === 'π' ? Math.PI : Math.E;
    if (t.k === 'ans') return c.ans;
    if (t.k === 'fn') return FUNCTIONS[t.v](op('(') ? (p++, group()) : unary(), c);
    if (t.k === 'op' && t.v === '(') return group();
    return fail(SYNTAX);
  };

  const v = sum();
  if (p < tokens.length) fail(SYNTAX);
  return v;
}

/* ---------- Showing numbers and sums ---------- */

const BOX = '<i class="box"></i>'; // what is still to be typed, drawn (a font may not have ▯)
const stacked = (n, d) => `<span class="frac"><span>${n}</span><span>${d}</span></span>`;
const minus = s => s.replace('-', '−');

function decimal(x) {
  if (x === 0) return { html: '0', text: '0' };
  let s = x.toPrecision(10); // the Casio's ten digits
  if (s.includes('e') || Math.abs(x) >= 1e10 || Math.abs(x) < 1e-9) {
    const [m, e] = x.toExponential(9).split('e');
    const mant = minus(m.includes('.') ? m.replace(/\.?0+$/, '') : m), exp = minus(String(Number(e)));
    return { html: `${mant}×10<sup>${exp}</sup>`, text: `${mant}×10^${exp}` };
  }
  if (s.includes('.')) s = s.replace(/\.?0+$/, '');
  return { html: minus(s), text: minus(s) };
}

/** How a value reads: { html, text }. `dec`: a fraction as a decimal. `mixed`: an improper fraction as a mixed number (2 1/3). */
export function format(v, { dec = false, mixed = false } = {}) {
  if (isFraction(v)) {
    const { n, d } = v;
    if (d === 1n && digits(n) <= 10) return { html: minus(n.toString()), text: minus(n.toString()) };
    if (d !== 1n && !dec && digits(n) <= 10 && digits(d) <= 10) {
      const sign = n < 0n ? '−' : '', top = abs(n);
      if (mixed && top > d) {
        const w = top / d, r = top % d;
        return { html: `${sign}${w}${stacked(r, d)}`, text: `${sign}${w} ${r}/${d}` };
      }
      return { html: sign + stacked(top, d), text: `${sign}${top}/${d}` };
    }
  }
  return decimal(toFloat(v));
}

const escape = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
const NUMBER = String.raw`(?:\d+\.?\d*|\.\d+)`;
const INVERSE = { asin: 'sin⁻¹', acos: 'cos⁻¹', atan: 'tan⁻¹' };

const CARET = '<i class="caret"></i>';

/** The sum as the textbook writes it: stacked fractions, raised powers, ×10ˣ. A half-typed fraction shows a box for what is missing.
 *  `caret`: the offset in the sum (between two characters) where the cursor is, drawn as a bar; -1: none.
 *  Inside a fraction or a power it is drawn inside it, so that where it is shows where the next digit goes. */
export function sumHtml(src, caret = -1) {
  const mark = pos => (pos === caret ? CARET : '');
  // Every piece draws the places after its characters and leaves the one before its first to whoever came before it.
  const run = (text, at) => [...text].map((c, k) => escape(c) + mark(at + k + 1)).join(''); // `text` begins at offset `at`
  const part = (text, at) => mark(at) + (text ? run(text, at) : BOX); // a part of a fraction, which the cursor may stand at the start of
  const draw = (str, off) => {
    let out = '';
    for (let i = 0; i < str.length;) {
      const rest = str.slice(i), at = off + i;
      let m;
      if ((m = new RegExp(String.raw`^(\d+)⌟(\d*)(⁄(\d*))?`).exec(rest))) { // a mixed number, typed so far
        const [, whole, top, bar, bottom] = m, topAt = at + whole.length + 1;
        out += run(whole, at) + stacked(part(top, topAt), bar ? part(bottom, topAt + top.length + 1) : BOX);
      } else if ((m = new RegExp(`^(${NUMBER})⁄(${NUMBER}?)`).exec(rest))) {
        out += stacked(run(m[1], at), part(m[2], at + m[1].length + 1));
      } else if (rest[0] === '^') {
        let j = 1;
        if (rest[1] === '(') { // the whole bracket is the exponent; its brackets are not shown (x⁻¹)
          let closed = false;
          for (let depth = 0; j < rest.length; j++) {
            depth += rest[j] === '(' ? 1 : rest[j] === ')' ? -1 : 0;
            if (!depth) { closed = true; j++; break; }
          }
          const inner = rest.slice(2, closed ? j - 1 : j);
          out += `<sup>${mark(at + 1)}${mark(at + 2)}${draw(inner, at + 2)}${closed ? mark(at + 3 + inner.length) : ''}</sup>`;
        } else {
          const e = new RegExp(`^[−-]?(?:${NUMBER}|Ans|π|e)`).exec(rest.slice(1));
          j = 1 + (e ? e[0].length : 0);
          out += `<sup>${mark(at + 1)}${e ? draw(e[0], at + 1) : BOX}</sup>`;
        }
        m = [rest.slice(0, j)];
      } else if ((m = /^E([−-]?\d*)/.exec(rest))) {
        out += `×10<sup>${mark(at + 1)}${m[1] ? run(m[1], at + 1) : BOX}</sup>`;
      } else if ((m = /^(?:asin|acos|atan)/.exec(rest))) {
        out += INVERSE[m[0]] + mark(at + m[0].length);
      } else {
        m = [rest[0]];
        out += escape(rest[0]) + mark(at + 1);
      }
      i += m[0].length;
    }
    return out;
  };
  return mark(0) + draw(src, 0);
}

/* ---------- The pane ---------- */

const key = (label, insert, cls = '', more = {}) => ({ label, insert, cls, ...more });
const digit = n => key(String(n), String(n));
const ARROW_LEFT = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg>';
const ARROW_RIGHT = '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5l7 7-7 7"/></svg>';
const BOXES = `<span class="frac"><span>${BOX}</span><span>${BOX}</span></span>`;
// `insert` goes into the sum. `post`: after an answer, carries on from it (Ans + …) instead of starting afresh.
// `alt`: what the key is while 2nd is on. `act`: a key that does something instead.
const ROWS = [
  [key('2nd', '', 'fn tog', { act: 'second' }), key('DEG', '', 'fn tog', { act: 'deg' }), key('(', '(', 'fn'), key(')', ')', 'fn'), key('⌫', '', 'fn', { act: 'back' }), key('AC', '', 'fn clr', { act: 'clear' }), key('÷', '÷', 'op', { post: 1 })],
  [key('sin', 'sin(', 'fn', { alt: ['sin<sup>−1</sup>', 'asin('] }), key('cos', 'cos(', 'fn', { alt: ['cos<sup>−1</sup>', 'acos('] }), key('tan', 'tan(', 'fn', { alt: ['tan<sup>−1</sup>', 'atan('] }), digit(7), digit(8), digit(9), key('×', '×', 'op', { post: 1 })],
  [key('ln', 'ln(', 'fn'), key('log', 'log(', 'fn'), key('e<sup>x</sup>', 'e^(', 'fn', { alt: ['10<sup>x</sup>', '10^('] }), digit(4), digit(5), digit(6), key('−', '−', 'op', { post: 1 })],
  [key('x<sup>2</sup>', '^2', 'fn', { post: 1, alt: ['x<sup>3</sup>', '^3'] }), key('√', '√(', 'fn', { alt: ['∛', '∛('] }), key('x<sup>y</sup>', '^', 'fn', { post: 1 }), digit(1), digit(2), digit(3), key('+', '+', 'op', { post: 1 })],
  [key('π', 'π', 'fn'), key('e', 'e', 'fn'), key('n!', '!', 'fn', { post: 1 }), digit(0), key('.', '.'), key('(−)', '−'), key('=', '', 'eq', { act: 'eval' })],
  [key(BOXES, '', 'fn', { act: 'frac', title: 'Fraction: type the top, tap this, type the bottom' }),
    key(BOX + BOXES, '', 'fn', { act: 'mixed', title: 'Mixed number (2 1/3). After an answer: show it as a mixed number or not' }),
    key('S⇔D', '', 'fn span3', { act: 'toggle', title: 'Answer as a fraction or as a decimal' }),
    key('x<sup>−1</sup>', '^(−1)', 'fn', { post: 1 }), key('×10<sup>x</sup>', 'E', 'fn')],
  // The cursor: back along the sum, forward along it. After an answer, ◀ goes back into the sum (to its end), ▶ to its start.
  [key(ARROW_LEFT, '', 'fn span3', { act: 'left', title: 'Move the cursor left' }),
    key(ARROW_RIGHT, '', 'fn span3', { act: 'right', title: 'Move the cursor right' }), key('Ans', 'Ans', 'fn')],
];

/** `panel`: #calc; `button`: the toolbar button that shows and hides it; `host`: the box it floats in and is kept inside. */
export function createCalc({ panel, button, host }) {
  const $ = sel => panel.querySelector(sel);
  const display = $('#calc-disp'), sumEl = $('#calc-ex'), answerEl = $('#calc-re'), mini = $('#calc-mini'), keys = $('#calc-keys');
  let sum = '', cursor = 0, done = false, error = '', answer = frac(0n), shown = null; // cursor: an offset in `sum`, where the next thing typed goes
  let deg = true, second = false, asDecimal = false, asMixed = false;
  let pos = { x: NaN, y: NaN };
  try { Object.assign(pos, JSON.parse(localStorage.getItem('calc'))); } catch { /* storage blocked, or nothing saved */ }
  panel.classList.toggle('min', pos.min === true);
  const save = () => { try { localStorage.setItem('calc', JSON.stringify({ x: pos.x, y: pos.y, min: panel.classList.contains('min') })); } catch { /* lasts for this visit only */ } };

  // The keys are made here, from ROWS.
  const buttons = [];
  for (const row of ROWS) {
    for (const k of row) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = `k ${k.cls}`;
      b.innerHTML = `<span>${k.label}</span>`;
      if (k.title) b.title = k.title;
      b.k = k;
      keys.append(b);
      buttons.push(b);
    }
  }
  const [secondBtn, degBtn] = buttons;
  keys.addEventListener('click', e => { const b = e.target.closest('.k'); if (b) press(b.k); });

  function render() {
    const typing = !done && !error;
    display.classList.toggle('typing', typing);
    display.classList.toggle('bad', !!error);
    display.classList.toggle('blank', typing && !sum);
    sumEl.innerHTML = sumHtml(sum, typing ? cursor : -1);
    // A long sum slides to keep the cursor in sight; an answered one shows its end.
    const bar = sumEl.querySelector('.caret');
    if (bar) {
      const left = bar.offsetLeft, right = left + bar.offsetWidth;
      if (left < sumEl.scrollLeft + 12) sumEl.scrollLeft = Math.max(0, left - 12);
      else if (right > sumEl.scrollLeft + sumEl.clientWidth - 12) sumEl.scrollLeft = right - sumEl.clientWidth + 12;
    } else sumEl.scrollLeft = sumEl.scrollWidth;
    shown = done ? format(answer, { dec: asDecimal, mixed: asMixed }) : null;
    answerEl.innerHTML = error || (shown ? shown.html : sum ? '' : '0');
    mini.textContent = shown ? shown.text : 'Calculator';
    secondBtn.setAttribute('aria-pressed', second);
    secondBtn.classList.toggle('on', second);
    degBtn.textContent = deg ? 'DEG' : 'RAD';
    for (const b of buttons) if (b.k.alt) b.innerHTML = `<span>${second ? b.k.alt[0] : b.k.label}</span>`;
  }

  // The number being typed is the one before the cursor: "12", "1⌟3": where a fraction bar or a mixed-number mark may go.
  const typedNumber = () => /[\d.⁄⌟E]+$/.exec(sum.slice(0, cursor))?.[0] ?? '';
  const wholeAtEnd = () => { const m = /(.?)(\d+)$/.exec(sum.slice(0, cursor)); return !!m && !(m[1] && '.⌟⁄E'.includes(m[1])); };
  // Where the cursor can stand: before and after each key's worth of the sum (sin( is one, so is Ans).
  const stops = () => [0, ...[...sum.matchAll(/asin\(|acos\(|atan\(|sin\(|cos\(|tan\(|ln\(|log\(|√\(|∛\(|\^\(|Ans|[^]/gu)].map(m => m.index + m[0].length)];
  const insert = text => { if (sum.length < 160) { sum = sum.slice(0, cursor) + text + sum.slice(cursor); cursor += text.length; } };

  function press(k) {
    const was2 = second;
    second = false;
    if (k.act === 'second') second = !was2;
    else if (k.act === 'deg') deg = !deg;
    else if (k.act === 'clear') { sum = ''; cursor = 0; done = false; error = ''; }
    else if (k.act === 'back') {
      if (done || error) { done = false; error = ''; cursor = sum.length; }
      const before = stops().filter(x => x < cursor).pop();
      if (before !== undefined) { sum = sum.slice(0, before) + sum.slice(cursor); cursor = before; }
    } else if (k.act === 'left') {
      if (done || error) { done = false; error = ''; cursor = sum.length; } else cursor = stops().filter(x => x < cursor).pop() ?? 0;
    } else if (k.act === 'right') {
      if (done || error) { done = false; error = ''; cursor = 0; } else cursor = stops().find(x => x > cursor) ?? sum.length;
    } else if (k.act === 'eval') {
      if (!sum) return render();
      try {
        const v = evaluate(sum, { ans: answer, deg });
        answer = v; done = true; asDecimal = false; asMixed = false;
      } catch (e) { error = /ERROR$/.test(e.message) ? e.message : SYNTAX; }
    } else if (k.act === 'toggle') {
      if (done && isFraction(answer) && answer.d !== 1n) asDecimal = !asDecimal;
    } else if (k.act === 'mixed') {
      if (done) { if (isFraction(answer) && answer.d !== 1n) { asMixed = !asMixed; asDecimal = false; } } else if (wholeAtEnd()) insert('⌟');
    } else if (k.act === 'frac') {
      const n = typedNumber();
      if (!done && /\d$/.test(n) && !n.includes('⁄') && !n.includes('E')) insert('⁄');
    } else {
      if (error) { sum = ''; cursor = 0; error = ''; done = false; }
      if (done) { sum = k.post ? 'Ans' : ''; cursor = sum.length; done = false; } // an operator goes on from the answer; anything else starts a new sum
      insert(was2 && k.alt ? k.alt[1] : k.insert);
    }
    render();
  }

  /* Placing, moving, showing */
  function place() {
    const h = host.getBoundingClientRect(), w = panel.offsetWidth, ht = panel.offsetHeight;
    if (!Number.isFinite(pos.x) || !Number.isFinite(pos.y)) { pos.x = h.width - w - 20; pos.y = 130; } // 130: clear of the toolbar and the tabs
    pos.x = Math.min(Math.max(pos.x, 6), Math.max(6, h.width - w - 6));
    pos.y = Math.min(Math.max(pos.y, 6), Math.max(6, h.height - ht - 6));
    panel.style.left = `${pos.x}px`;
    panel.style.top = `${pos.y}px`;
  }

  /* Motion, as iOS moves things: the pane grows out of the toolbar's button and goes back into it; the dash
     takes it down to a chip, and out of the chip again. It is placed with left and top, never a transform, so
     the one `transform` these use is the only one it has (the iPad drops a transform that another property
     moves alongside). One motion at a time: a tap in the middle of one finishes it, and goes on from there. */
  const still = matchMedia('(prefers-reduced-motion: reduce)');
  const SOFT = 'cubic-bezier(.32, .72, 0, 1)'; // iOS: a quick start and a long, soft landing
  let motion = null;                           // { animations, done }
  const stop = () => {
    if (!motion) return;
    const { animations, done } = motion;
    motion = null;
    done();
    for (const a of animations) a.cancel();
  };
  const go = (animations, done) => {
    stop();
    const m = motion = { animations, done };
    let left = animations.length;
    for (const a of animations) {
      a.onfinish = () => {
        if (motion !== m || --left) return;
        motion = null;
        done();
        for (const x of animations) x.cancel(); // what a motion held at its end (fill) is let go once the real state is the same
      };
    }
  };
  // Where the toolbar's button is, as a point of the pane: what it grows from and shrinks to.
  const towardsButton = () => {
    const b = button.getBoundingClientRect(), r = panel.getBoundingClientRect();
    return b.width ? `${b.left + b.width / 2 - r.left}px ${b.top + b.height / 2 - r.top}px` : '50% 0';
  };

  let open = false;
  const show = on => {
    if (on === open) return;
    open = on;
    button.setAttribute('aria-pressed', on);
    stop();
    if (on) {
      panel.hidden = false;
      place();
      if (still.matches) return;
      panel.style.transformOrigin = towardsButton();
      go([panel.animate([{ transform: 'scale(.4)', opacity: 0 }, { transform: 'scale(1)', opacity: 1 }], { duration: 480, easing: 'cubic-bezier(.3, 1.25, .5, 1)' })],
        () => { panel.style.transformOrigin = ''; });
    } else if (still.matches) {
      panel.hidden = true;
    } else {
      panel.style.transformOrigin = towardsButton();
      go([panel.animate([{ transform: 'scale(1)', opacity: 1 }, { transform: 'scale(.4)', opacity: 0 }], { duration: 260, easing: 'cubic-bezier(.5, 0, .9, .6)', fill: 'forwards' })],
        () => { panel.hidden = true; panel.style.transformOrigin = ''; });
    }
  };

  // Down to a chip, or back up: the pane's box glides from the old one to the new, and its body fades out as it goes
  // (in as it comes), kept in view meanwhile (.morphing) so that it is not cut off at once.
  const boxOf = () => ({ left: `${pos.x}px`, top: `${pos.y}px`, width: `${panel.offsetWidth}px`, height: `${panel.offsetHeight}px` });
  function shrink(chip) {
    if (chip === panel.classList.contains('min')) return;
    stop();
    const was = boxOf();
    panel.classList.toggle('min', chip);
    place(); // a pane near the bottom edge has to move up to grow
    const now = boxOf();
    save();
    if (still.matches) return;
    panel.classList.add('morphing');
    const body = chip ? { frames: [{ opacity: 1 }, { opacity: 0 }], duration: 260, delay: 0 } : { frames: [{ opacity: 0 }, { opacity: 1 }], duration: 340, delay: 140 };
    go([
      panel.animate([was, now], { duration: 520, easing: SOFT }),
      ...[display, keys].map(el => el.animate(body.frames, { duration: body.duration, delay: body.delay, easing: 'ease', fill: 'both' })),
      mini.animate([{ opacity: chip ? 0 : 1 }, { opacity: chip ? 1 : 0 }], { duration: 260, delay: chip ? 220 : 0, easing: 'ease', fill: 'both' }),
    ], () => panel.classList.remove('morphing'));
  }

  button.addEventListener('click', () => show(!open));
  $('#calc-close').addEventListener('click', () => show(false));
  $('#calc-min').addEventListener('click', () => shrink(!panel.classList.contains('min')));
  addEventListener('resize', () => { if (open) place(); });

  // Dragged by the handle; a finger or the Pencil, kept inside the note's window.
  const grip = $('#calc-grip');
  let from = null;
  grip.addEventListener('pointerdown', e => { from = { x: e.clientX - pos.x, y: e.clientY - pos.y }; grip.setPointerCapture(e.pointerId); });
  grip.addEventListener('pointermove', e => { if (from) { pos.x = e.clientX - from.x; pos.y = e.clientY - from.y; place(); } });
  for (const type of ['pointerup', 'pointercancel']) grip.addEventListener(type, () => { if (from) { from = null; save(); } });

  render();
  return { show };
}
