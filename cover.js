// cover.js — the promo cover: a 16:9 title page for EngiKode (the channel, the website, the courses), put in
// front of a note. Plain ES module; nothing here needs the app. What a note does with it is in pages.js.
//
// The look is the site's own (engikode.vercel.app): paper, ink green, lime, coral, DM Mono labels, Manrope
// headlines with a Source Serif italic, hard offset shadows. The words are the site's, so they stay true;
// the links are in PROMO, the one place to change them.
//
// The cover is a frame of its own inside the note (a srcdoc, no scripts), so that the note's styles cannot
// reach it and it cannot reach the note's, and it is the same in the editor, on a card and in an export.
import { COVER_FONTS } from './cover-fonts.js';

export const COVER_H = 506;                 // 900 wide, so 16:9: a whole frame of the recording
export const COVER_MARK = 'data-enginote-cover';

const PROMO = {
  youtube: 'youtube.com/@EngiKode',
  handle: '@EngiKode',
  site: 'engikode.vercel.app',
};

const MARK = '<svg viewBox="0 0 457.26 304.89" fill="#fff"><polygon points="457.26 0 378.29 0 197.77 243.9 197.78 304.89 430.53 304.88 330.01 182.91 457.26 0"/><polygon points="197.77 182.93 0 182.93 0 121.95 197.77 121.95"/><rect y="243.9" width="263.68" height="60.99"/><polygon points="197.77 60.98 0 60.98 0 0 197.77 0"/></svg>';
const WORD = '<svg class="word" viewBox="0 0 617.66 90.19"><path d="M53.37,18.44H16.24v17.57h34.06v16.94H16.24v18.81h37.13v16.94H0V1.5h53.37v16.94Z"/><path d="M126.5,62.41l-1.48-24.42V1.5h16.24v87.2h-18.73l-34.52-61.04,1.48,24.54v36.5h-16.24V1.5h18.62l34.63,60.92Z"/><path d="M240.11,41.36v47.34h-13.85v-14.7c-3.63,9.34-13.4,16.19-26.8,16.19-22.14,0-39.51-18.81-39.51-44.97S177.31,0,201.04,0c18.96,0,33.72,12.46,38.38,30.4h-17.37c-3.75-8.35-11.35-13.45-21.12-13.45-14.65,0-24.64,11.71-24.64,28.53,0,15.82,8.86,28.28,24.41,28.28,10.9,0,19.87-6.23,22.71-17.44h-26.8v-14.95h43.49Z"/><path d="M262.5,1.5h16.24v87.2h-16.24V1.5Z"/><path d="M334.72,43.73l33.16,44.97h-20.33l-29.86-40.61v40.61h-16.24V1.5h16.24v38.49L345.96,1.5h20.1l-31.34,42.23Z"/><path d="M457.26,45.1c0,25.66-18.05,45.1-41.44,45.1s-41.33-19.44-41.33-45.1S392.42,0,415.81,0s41.44,19.43,41.44,45.1ZM390.83,45.1c0,16.32,10.67,28.16,24.98,28.16s24.98-11.84,24.98-28.16-10.67-28.15-24.98-28.15-24.98,11.84-24.98,28.15Z"/><path d="M476.21,1.5h28.73c23.16,0,40.65,18.56,40.65,43.6s-17.49,43.6-40.65,43.6h-28.73V1.5ZM504.93,71.76c14.31,0,24.41-10.96,24.41-26.66s-10.11-26.66-24.41-26.66h-12.49v53.32h12.49Z"/><path d="M617.66,18.44h-37.13v17.57h34.06v16.94h-34.06v18.81h37.13v16.94h-53.37V1.5h53.37v16.94Z"/></svg>';
const GO = '<svg viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6"/></svg>';

const CSS = `
*{box-sizing:border-box;margin:0}
html,body{width:900px;height:${COVER_H}px;overflow:hidden;background:#f5f1e8}
body{position:relative;font-family:Manrope,'Avenir Next',system-ui,sans-serif;color:#172620;-webkit-font-smoothing:antialiased}
.m{font-family:'DM Mono',ui-monospace,Menlo,monospace;font-weight:500}
.d{position:absolute;border-radius:50%}
.o1{width:560px;height:560px;right:-150px;top:-120px;border:1px solid rgba(101,129,59,.2)}
.o2{width:400px;height:400px;right:-70px;top:-40px;border:1px solid rgba(101,129,59,.14)}
.lime{width:310px;height:310px;right:20px;top:86px;background:rgba(223,255,114,.5)}
.peach{width:170px;height:170px;left:-50px;bottom:-60px;background:#f4d3b9}
.brand{position:absolute;left:48px;top:32px;display:flex;align-items:center;gap:11px}
.mark{width:34px;height:34px;padding:7px 6px;background:#172620;border-radius:8px;box-shadow:2px 3px 0 rgba(23,38,32,.2);transform:rotate(-6deg)}
.mark svg{display:block;width:100%;height:100%}
.word{display:block;height:15px;width:auto;fill:#172620}
.chip{position:absolute;right:48px;top:39px;font-size:9px;letter-spacing:.08em;background:#dfff72;padding:7px 9px}
.eyebrow{position:absolute;left:48px;top:122px;font-size:10px;letter-spacing:.13em;display:flex;align-items:center;gap:13px}
.eyebrow i{width:8px;height:8px;border-radius:50%;background:#f19d5b;box-shadow:0 0 0 4px #f5dfbd}
h1{position:absolute;left:46px;top:148px;font-weight:800;font-size:54px;line-height:.98;letter-spacing:-.052em}
h1 em{font-family:'Source Serif 4',Georgia,serif;font-style:italic;font-weight:600;color:#668040;letter-spacing:-.035em;font-size:1.04em}
.lede{position:absolute;left:48px;top:318px;width:390px;font-weight:600;font-size:14px;line-height:1.7;color:#53605a}
.cta{position:absolute;left:48px;top:388px;display:flex;align-items:center;gap:20px}
.btn{display:flex;align-items:center;gap:12px;background:#172620;color:#fffdf7;font-weight:800;font-size:12px;padding:15px 20px 15px 16px;border-radius:3px;box-shadow:5px 5px 0 #dfff72}
.play{width:20px;height:20px;border-radius:50%;background:#f68b72;display:grid;place-items:center}
.play:after{content:'';border-left:6px solid #fff;border-top:4px solid transparent;border-bottom:4px solid transparent;margin-left:2px}
.handle{font-size:11px;letter-spacing:.04em;border-bottom:1px solid #85918b;padding-bottom:4px}
.card{position:absolute;width:290px;padding:19px 20px 17px;border-radius:5px;border:1px solid rgba(23,38,32,.09);box-shadow:6px 7px 0 rgba(37,52,44,.1);transform:rotate(var(--r))}
.card:before{content:'';position:absolute;top:-1px;left:20px;width:46px;height:8px;background:rgba(255,255,255,.55);border-radius:0 0 4px 4px}
.k{font-size:9px;letter-spacing:.08em;color:#667168}
.card h3{font-family:'Source Serif 4',Georgia,serif;font-style:italic;font-weight:600;font-size:27px;line-height:.98;letter-spacing:-.04em;margin:13px 0 8px}
.card p{font-weight:600;font-size:10.5px;line-height:1.55;color:#526058;max-width:215px}
.go{position:absolute;right:16px;top:15px;width:26px;height:26px;border:1px solid rgba(23,38,32,.38);border-radius:50%;display:grid;place-items:center}
.go svg{width:12px;height:12px;stroke:#172620;fill:none;stroke-width:2.2;stroke-linecap:round;stroke-linejoin:round}
.c1{left:548px;top:70px;--r:-3deg;background:#dfff72;z-index:3}
.c2{left:528px;top:192px;--r:2deg;background:#fffdf7;z-index:2}
.c3{left:556px;top:312px;--r:-1.5deg;background:#f8d9d0}
.foot{position:absolute;left:48px;right:48px;bottom:26px;display:flex;justify-content:space-between;border-top:1px solid rgba(23,38,32,.17);padding-top:12px;font-size:10px;letter-spacing:.05em;color:#7d8881}
.foot b{font-weight:500;color:#172620;margin-left:8px}
/* The entrance: only where the editor asks for it (class "live", pages.js), so a card, a page picture or an
   export shows the finished cover at once. Each part rises in turn. */
@keyframes rise{from{opacity:0;transform:translateY(16px)}}
@keyframes land{from{opacity:0;transform:translateY(30px) rotate(calc(var(--r) - 4deg))}}
@keyframes fade{from{opacity:0}}
.live .r{animation:rise .85s cubic-bezier(.2,.8,.25,1) both;animation-delay:calc(var(--i,0) * 90ms + 100ms)}
.live .card{animation-name:land}
.live .d{animation:fade 1.4s ease both}
@media (prefers-reduced-motion:reduce){.live *{animation:none!important}}
`;

const BODY = `
<div class="d o1"></div><div class="d o2"></div><div class="d lime"></div><div class="d peach"></div>
<div class="brand r" style="--i:0"><div class="mark">${MARK}</div>${WORD}</div>
<div class="chip m r" style="--i:1">EXPLAINED WITHOUT THE NOISE</div>
<div class="eyebrow m r" style="--i:2"><i></i>LEARN WITH ENGIKODE</div>
<h1 class="r" style="--i:3">Learning that<br>finally<br><em>makes sense.</em></h1>
<p class="lede r" style="--i:5">Clear explanations, guided courses and free notes, all in one calm place.</p>
<div class="cta r" style="--i:6"><div class="btn"><span class="play"></span>Subscribe on YouTube</div><span class="handle m">${PROMO.handle}</span></div>
<div class="card c1 r" style="--i:4"><span class="go">${GO}</span><div class="k m">01 / COURSES</div><h3>Week by week.</h3><p>Lectures, materials and live sessions in one classroom.</p></div>
<div class="card c2 r" style="--i:5"><span class="go">${GO}</span><div class="k m">02 / NOTES</div><h3>Ready to revise.</h3><p>Free notes to read and download, Plus notes for deeper topics.</p></div>
<div class="card c3 r" style="--i:6"><span class="go">${GO}</span><div class="k m">03 / PRACTICE</div><h3>Test yourself.</h3><p>Quizzes, timed or at your own pace.</p></div>
<div class="foot m r" style="--i:7"><span>YOUTUBE<b>${PROMO.youtube}</b></span><span>WEBSITE<b>${PROMO.site}</b></span><span>COURSES · NOTES · PRACTICE</span></div>
`;

const doc = live => `<!doctype html><html${live ? ' class="live"' : ''}><head><meta charset="utf-8"><style>${COVER_FONTS}${CSS}</style></head><body>${BODY}</body></html>`;
const attr = text => text.replace(/[&<>"]/g, c => `&#${c.charCodeAt(0)};`);

/** The cover as an <iframe>. `live`: it makes its entrance (the editor); otherwise it is simply there.
    `floating`: laid over the top of the page, for a note that has its own HTML (see coverStyle). */
export function coverFrame({ live = false, floating = false } = {}) {
  const style = `display:block;width:900px;height:${COVER_H}px;max-width:none;margin:0;padding:0;border:0;` +
    (floating ? 'position:absolute!important;left:0!important;top:0!important;z-index:1;' : '');
  return `<iframe ${COVER_MARK} title="EngiKode" tabindex="-1" aria-hidden="true" scrolling="no" style="${style}" srcdoc="${attr(doc(live))}"></iframe>`;
}

/** What an HTML note needs besides the frame: room for it. The frame lies over the top of the page and
    this pushes everything else down by exactly its height, whatever the note's own margins are
    (the root's padding is never shared with a margin). border-box: a note of a set height stays that tall.
    ponytail: a note whose own <html> has top padding loses it, and one whose <body> is positioned puts
    the cover from the body's corner. Neither has been met. */
export const coverStyle = `<style ${COVER_MARK}>html{padding-top:${COVER_H}px!important;box-sizing:border-box!important}</style>`;
