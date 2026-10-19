// Checks for calc.js: `node calc.test.mjs`. Prints one line per failure and exits 1 if there is any.
import { evaluate, format, sumHtml } from './calc.js';

let bad = 0;
const check = (name, got, want) => { if (got !== want) { bad++; console.log(`FAIL ${name}: got ${got}, want ${want}`); } };
const text = (src, ctx, opts) => { try { return format(evaluate(src, ctx), opts).text; } catch (e) { return e.message; } };

// fractions stay fractions
check('1÷3', text('1÷3'), '1/3');
check('1/3+1/6', text('1⁄3+1⁄6'), '1/2');
check('mixed in', text('1⌟3⁄4'), '7/4');
check('mixed out', text('7÷4', {}, { mixed: true }), '1 3/4');
check('negative mixed', text('−7÷4', {}, { mixed: true }), '−1 3/4');
check('S⇔D', text('1÷3', {}, { dec: true }), '0.3333333333');
check('0.1+0.2 exact', text('0.1+0.2'), '3/10');
check('(2/3)^2', text('(2⁄3)^2'), '4/9');
check('x⁻¹', text('(3⁄4)^(−1)'), '4/3');
check('sqrt exact', text('√(1⁄4)'), '1/2');
check('sqrt 16', text('√(16)'), '4');
check('cbrt', text('∛(27)'), '3');
check('x^(3/2)', text('4^(3⁄2)'), '8');
check('2^10', text('2^10'), '1024');
check('5!', text('5!'), '120');
check('1E3', text('1E3'), '1000');
check('2E−3', text('2E−3'), '1/500');
// the order of working
check('precedence', text('2+3×4'), '14');
check('−2²', text('−2^2'), '−4');
check('2^−1', text('2^−1'), '1/2');
check('implicit ×', text('2(3+4)'), '14');
check('open bracket at the end', text('2×(3+4'), '14');
check('Ans', text('Ans×2', { ans: { n: 3n, d: 4n } }), '3/2');
// trig, logs
check('sin30', text('sin(30)'), '1/2');
check('cos60', text('cos(60)'), '1/2');
check('sin390', text('sin(390)'), '1/2');
check('cos90', text('cos(90)'), '0');
check('tan45', text('tan(45)'), '1');
check('sin20', text('sin(20)'), '0.3420201433');
check('asin(1/2)', text('asin(1⁄2)'), '30');
check('atan1', text('atan(1)'), '45');
check('sin π rad', text('sin(π)', { deg: false }), '0');
check('log1000', text('log(1000)'), '3');
check('log0.01', text('log(1⁄100)'), '−2');
check('ln1', text('ln(1)'), '0');
check('ln e', text('ln(e)'), '1');
check('π', text('π'), '3.141592654');
check('example value', text('18^2×sin(70)÷9.81').slice(0, 5), '31.03');
// big and small
check('big', text('99999×99999'), '9999800001');
check('sci', text('10^12'), '1×10^12');
check('small', text('1÷10^10', {}, { dec: true }), '1×10^−10');
// errors
check('÷0', text('1÷0'), 'Math ERROR');
check('tan90', text('tan(90)'), 'Math ERROR');
check('√−1', text('√(−1)'), 'Math ERROR');
check('ln0', text('ln(0)'), 'Math ERROR');
check('70!', text('70!'), 'Math ERROR');
check('syntax', text('2+×3'), 'Syntax ERROR');
check('stray )', text('2)'), 'Syntax ERROR');
check('empty', String(evaluate('')), 'null');
// the picture of a sum
check('html frac', sumHtml('3⁄4'), '<span class="frac"><span>3</span><span>4</span></span>');
check('html half-typed', sumHtml('3⁄'), '<span class="frac"><span>3</span><span><i class="box"></i></span></span>');
check('html power', sumHtml('x^2'.replace('x', '5')), '5<sup>2</sup>');
check('html x⁻¹', sumHtml('4^(−1)'), '4<sup>−1</sup>');
check('html inverse', sumHtml('asin(1⁄2)'), 'sin⁻¹(<span class="frac"><span>1</span><span>2</span></span>)');

// the cursor is drawn where it is, inside a fraction or a power when that is where the next digit goes
const C = '<i class="caret"></i>', F = (a, b) => `<span class="frac"><span>${a}</span><span>${b}</span></span>`;
check('caret at the start', sumHtml('12', 0), C + '12');
check('caret between digits', sumHtml('12', 1), '1' + C + '2');
check('caret at the end', sumHtml('1+2', 3), '1+2' + C);
check('caret in a numerator', sumHtml('12⁄34', 1), F('1' + C + '2', '34'));
check('caret at the end of a numerator', sumHtml('12⁄34', 2), F('12' + C, '34'));
check('caret at the start of a denominator', sumHtml('12⁄34', 3), F('12', C + '34'));
check('caret at the end of a denominator', sumHtml('12⁄34', 5), F('12', '34' + C));
check('caret in an empty denominator', sumHtml('3⁄', 2), F('3', C + '<i class="box"></i>'));
check('caret after a fraction and a sign', sumHtml('3⁄4+', 4), F('3', '4') + '+' + C);
check('caret in a power', sumHtml('5^23', 3), '5<sup>2' + C + '3</sup>');
check('caret at the start of a power', sumHtml('5^23', 2), '5<sup>' + C + '23</sup>');
check('caret in x⁻¹', sumHtml('4^(−1)', 5), '4<sup>−1' + C + '</sup>');
check('caret in a mixed number', sumHtml('1⌟34⁄5', 3), '1' + F('3' + C + '4', '5'));
check('no caret asked, none drawn', sumHtml('12⁄34'), F('12', '34'));

console.log(bad ? `${bad} failed` : 'all passed');
process.exit(bad ? 1 : 0);
