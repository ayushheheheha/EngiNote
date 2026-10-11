// shapes.js — what a rough drawing was meant to be: a straight line, an ellipse, a rectangle or a
// triangle. Pure geometry, no DOM, so it can be tested directly (ink.test.html). ink.js asks it
// when the tip is held still at the end of a stroke.
// It would rather say "nothing" than guess: a wrong shape is worse than none.

// All chosen on drawn-by-program shapes, not with the hardware to hand: tune on the real device.
const SNAP_ANGLE = 3 * Math.PI / 180;   // a line this close to level, upright or 45° is put exactly on it
const LINE_BEND = 0.05;   // a line may stray from straight by this share of its length
const CLOSE = 0.2;        // the ends of a closed shape meet within this share of its size
const FIT = 0.025;        // its points lie this close to the clean shape on average, as a share of its size...
const FIT_WORST = 0.05;   // ...and nine in ten of them this close (a few may stray: the tail where the ends cross).
                          // ponytail: a six-sided drawing with a shaky hand still passes for an ellipse now and then; telling
                          // those apart needs corners to be found, not only distances measured.
const UPRIGHT = 10;       // degrees: a shape tilted less than this is tried upright first
const ROUND = 0.1;        // an ellipse whose radii differ by less than this share is a circle
const SLIVER = 0.15;      // narrower than this share of its length, a closed drawing is no shape (a line gone over twice)
const STEP = 3;           // the clean shape has a point about every this many units along it
const SAMPLES = 72;       // the drawing is judged by this many points, evenly spaced along it

const round2 = n => Math.round(n * 100) / 100;
const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);
const lengthOf = pts => pts.reduce((sum, p, i) => sum + (i ? dist(p, pts[i - 1]) : 0), 0);
// A point as seen in a frame turned by `t` radians; turn(p, -t) brings it back.
const turn = ([x, y], t) => [x * Math.cos(t) + y * Math.sin(t), y * Math.cos(t) - x * Math.sin(t)];
const nearest = (p, pts) => Math.min(...pts.map(q => dist(p, q)));

function boxOf(pts) {
  const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]);
  return [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
}

// Distance from p to the segment a-b. (ink.js has the same; this file stands alone.)
function toSegment(p, a, b) {
  const dx = b[0] - a[0], dy = b[1] - a[1], len2 = dx * dx + dy * dy;
  const t = len2 ? Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2)) : 0;
  return Math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy);
}

/** Where a straight line from `a` should end for a tip at `b`: on the level, the upright or a 45° through `a` when it is within 3° of one. */
export function aim(a, b) {
  const dx = b[0] - a[0], dy = b[1] - a[1], angle = Math.atan2(dy, dx);
  const even = Math.round(angle / (Math.PI / 4)) * (Math.PI / 4);
  if (Math.abs(angle - even) > SNAP_ANGLE) return [b[0], b[1]];
  const along = Math.hypot(dx, dy) * Math.cos(angle - even);
  return [round2(a[0] + along * Math.cos(even)), round2(a[1] + along * Math.sin(even))];
}

// About `n` points evenly spaced along the path, its two ends among them.
function resample(pts, n) {
  const step = lengthOf(pts) / (n - 1), out = [pts[0]];
  let need = step;   // how far along the path the next one is
  for (let i = 1; i < pts.length; i++) {
    let a = pts[i - 1], d = dist(a, pts[i]);
    while (d >= need && d > 0) {
      a = [a[0] + (pts[i][0] - a[0]) * need / d, a[1] + (pts[i][1] - a[1]) * need / d];
      out.push(a);
      d -= need;
      need = step;
    }
    need -= d;
  }
  if (out.length < n) out.push(pts[pts.length - 1]);
  return out;
}

// The tilt (radians, 0 to a quarter turn) of the smallest box that holds the points, and that box's sides.
function tiltOf(pts) {
  const sides = t => { const [x0, y0, x1, y1] = boxOf(pts.map(p => turn(p, t))); return [x1 - x0, y1 - y0]; };
  const area = t => sides(t)[0] * sides(t)[1];
  let best = 0;
  // every degree, then every tenth of one around the best of those
  for (const [from, to, step] of [[0, 90, 1], [-1, 1, 0.1]]) {
    const middle = best;
    for (let deg = from; deg <= to; deg += step) {
      const t = middle + deg * Math.PI / 180;
      if (area(t) < area(best)) best = t;
    }
  }
  return [best, sides(best)];
}

// The candidates. Each is { kind, far(p): how far p lies from its outline, around: the length of that outline, points }.

function ellipse(pts, t) {
  const seen = pts.map(p => turn(p, t)), [x0, y0, x1, y1] = boxOf(seen);
  const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
  let rx = (x1 - x0) / 2, ry = (y1 - y0) / 2;
  // The box goes round the outside of the wobble: the ellipse that was meant runs down the middle of it.
  const mean = seen.reduce((sum, [x, y]) => sum + Math.hypot((x - cx) / rx, (y - cy) / ry), 0) / seen.length;
  rx *= mean;
  ry *= mean;
  if (Math.abs(rx - ry) < ROUND * Math.max(rx, ry)) rx = ry = (rx + ry) / 2;
  const around = Math.PI * (3 * (rx + ry) - Math.sqrt((3 * rx + ry) * (rx + 3 * ry)));   // Ramanujan's
  const n = Math.max(24, 4 * Math.ceil(around / STEP / 4)), points = [];   // in fours: its outermost four points are among them
  for (let i = 0; i < n; i++) {
    const [x, y] = turn([cx + rx * Math.cos(i / n * 2 * Math.PI), cy + ry * Math.sin(i / n * 2 * Math.PI)], -t);
    points.push([round2(x), round2(y)]);
  }
  points.push([...points[0]]);
  return {
    kind: 'ellipse', around, points,
    // along the ray from the centre: close enough to the true distance for a drawing that is nearly on it
    far(p) {
      const [x, y] = turn(p, t), r = Math.hypot(x - cx, y - cy), scaled = Math.hypot((x - cx) / rx, (y - cy) / ry);
      return scaled ? Math.abs(r - r / scaled) : Math.min(rx, ry);
    },
  };
}

// A closed shape with straight sides. Its points run along each side in turn, and a corner is there
// twice (the end of one side, the start of the next): that is what makes pathData() in ink.js turn
// sharply there instead of rounding it off.
function polygon(kind, corners) {
  const sides = corners.map((c, i) => [c, corners[(i + 1) % corners.length]]), points = [];
  for (const [a, b] of sides) {
    const n = Math.max(1, Math.round(dist(a, b) / STEP));
    for (let i = 0; i <= n; i++) points.push([round2(a[0] + (b[0] - a[0]) * i / n), round2(a[1] + (b[1] - a[1]) * i / n)]);
  }
  return { kind, points, around: lengthOf([...corners, corners[0]]), far: p => Math.min(...sides.map(([a, b]) => toSegment(p, a, b))) };
}

function rect(pts, t) {
  const seen = pts.map(p => turn(p, t)), box = boxOf(seen);
  // Each side runs through the middle of the points drawn along it, not round the outside of them.
  const sum = [0, 0, 0, 0], count = [0, 0, 0, 0];
  for (const [x, y] of seen) {
    const gaps = [x - box[0], y - box[1], box[2] - x, box[3] - y], side = gaps.indexOf(Math.min(...gaps));
    sum[side] += side % 2 ? y : x;
    count[side]++;
  }
  const [left, top, right, bottom] = box.map((edge, i) => (count[i] ? sum[i] / count[i] : edge));
  return polygon('rect', [[left, top], [right, top], [right, bottom], [left, bottom]].map(p => turn(p, -t)));
}

// The straight line that best fits some points: a point on it and its direction.
function lineThrough(pts) {
  const cx = pts.reduce((s, p) => s + p[0], 0) / pts.length, cy = pts.reduce((s, p) => s + p[1], 0) / pts.length;
  let xx = 0, yy = 0, xy = 0;
  for (const [x, y] of pts) { xx += (x - cx) ** 2; yy += (y - cy) ** 2; xy += (x - cx) * (y - cy); }
  const t = Math.atan2(2 * xy, xx - yy) / 2;
  return { at: [cx, cy], dir: [Math.cos(t), Math.sin(t)] };
}

function triangle(pts) {
  // Its corners, roughly: the three points of the drawing that span the biggest triangle.
  let most = -1, at = [0, 1, 2];
  for (let i = 0; i < pts.length; i++) for (let j = i + 1; j < pts.length; j++) for (let k = j + 1; k < pts.length; k++) {
    const area = Math.abs((pts[j][0] - pts[i][0]) * (pts[k][1] - pts[i][1]) - (pts[k][0] - pts[i][0]) * (pts[j][1] - pts[i][1]));
    if (area > most) { most = area; at = [i, j, k]; }
  }
  // Then exactly: each side is the line that best fits what was drawn between two corners (leaving
  // out the part near them, where a hand rounds the turn), and the corners are where those lines cross.
  const [i, j, k] = at;
  const lines = [pts.slice(i, j + 1), pts.slice(j, k + 1), [...pts.slice(k), ...pts.slice(0, i + 1)]].map(side => {
    const trim = Math.floor(side.length / 5);
    return lineThrough(side.length - 2 * trim > 2 ? side.slice(trim, side.length - trim) : [side[0], side[side.length - 1]]);
  });
  let corners = [[lines[2], lines[0], pts[i]], [lines[0], lines[1], pts[j]], [lines[1], lines[2], pts[k]]].map(([a, b, rough]) => {
    const cross = a.dir[0] * b.dir[1] - a.dir[1] * b.dir[0];
    if (Math.abs(cross) < 0.1) return rough;   // the two sides are all but parallel: no corner to be had from them
    const along = ((b.at[0] - a.at[0]) * b.dir[1] - (b.at[1] - a.at[1]) * b.dir[0]) / cross;
    return [a.at[0] + along * a.dir[0], a.at[1] + along * a.dir[1]];
  });
  // A side that is all but level or upright is made so, by turning the whole triangle that little bit about its middle.
  const mid = [0, 1].map(axis => (corners[0][axis] + corners[1][axis] + corners[2][axis]) / 3);
  const offs = corners.map((c, n) => {
    const next = corners[(n + 1) % 3], angle = Math.atan2(next[1] - c[1], next[0] - c[0]);
    return angle - Math.round(angle / (Math.PI / 2)) * (Math.PI / 2);
  }).sort((a, b) => Math.abs(a) - Math.abs(b));
  if (Math.abs(offs[0]) < UPRIGHT / 2 * Math.PI / 180) {
    corners = corners.map(c => { const [x, y] = turn([c[0] - mid[0], c[1] - mid[1]], offs[0]); return [x + mid[0], y + mid[1]]; });
  }
  return polygon('triangle', corners);
}

/**
 * What the drawing `points` ([[x, y, ...], ...], in order) was meant to be:
 * { kind: 'line' | 'ellipse' | 'rect' | 'triangle', points: the clean shape's [[x, y], ...] }, or null
 * for anything else (handwriting, a scribble, an open curve).
 * `min` is the smallest line worth straightening, in the points' own units; a closed shape must be half as big again.
 */
export function recognise(points, min = 24) {
  if (!Array.isArray(points) || points.length < 2) return null;
  const first = points[0], last = points[points.length - 1], chord = dist(first, last);

  // A straight line: every point near the line between the ends, and never going back along it.
  if (chord >= min) {
    const ux = (last[0] - first[0]) / chord, uy = (last[1] - first[1]) / chord, bend = Math.max(LINE_BEND * chord, min / 12);
    let reached = 0, straight = true;
    for (const p of points) {
      const along = (p[0] - first[0]) * ux + (p[1] - first[1]) * uy, off = Math.abs((p[0] - first[0]) * uy - (p[1] - first[1]) * ux);
      if (off > bend || along < reached - 2 * bend || along > chord + bend) { straight = false; break; }
      reached = Math.max(reached, along);
    }
    if (straight) return { kind: 'line', points: [[first[0], first[1]], aim(first, last)] };
  }

  // A closed shape: the end of the drawing comes back to its beginning (or runs on a little past it).
  const pts = resample(points, SAMPLES), box = boxOf(pts), drawn = lengthOf(pts);
  const size = (box[2] - box[0] + box[3] - box[1]) / 2, third = Math.ceil(pts.length / 3);
  if (size < min * 1.5) return null;
  if (Math.min(nearest(last, pts.slice(0, third)), nearest(first, pts.slice(-third))) > CLOSE * size) return null;
  const [tilt, [w, h]] = tiltOf(pts);
  if (Math.min(w, h) < SLIVER * Math.max(w, h)) return null;

  // Each candidate is laid over the drawing; the one it lies closest to wins, if that is close enough.
  const three = triangle(pts), limit = Math.floor(pts.length * 0.9);
  const judge = shape => {
    const off = pts.map(shape.far).sort((a, b) => a - b);
    return { shape, mean: off.reduce((a, b) => a + b, 0) / off.length, worst: off[limit] };
  };
  const quarter = Math.PI / 2, lean = Math.abs(tilt - Math.round(tilt / quarter) * quarter) * 180 / Math.PI;
  for (const t of lean < UPRIGHT ? [0, tilt] : [tilt]) {
    const best = [ellipse(pts, t), rect(pts, t), three].map(judge).sort((a, b) => a.mean - b.mean)[0];
    const turns = drawn / best.shape.around;
    if (best.mean <= FIT * size && best.worst <= FIT_WORST * size && turns > 0.8 && turns < 1.4) {
      return { kind: best.shape.kind, points: best.shape.points };
    }
  }
  return null;
}
