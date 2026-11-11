import CoreGraphics
import Foundation

/// What a rough drawing was meant to be: a straight line, an ellipse, a rectangle or a triangle.
/// A port of the web app's shapes.js (same constants, same tests); it would rather say nil than guess.
enum Shapes {
    static let snapAngle = 3 * Double.pi / 180
    static let lineBend = 0.05, close = 0.2, fit = 0.025, fitWorst = 0.05
    static let upright = 10.0, round = 0.1, sliver = 0.15, step = 3.0
    static let samples = 72

    typealias P = CGPoint

    private static func dist(_ a: P, _ b: P) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private static func length(_ pts: [P]) -> Double { zip(pts, pts.dropFirst()).reduce(0) { $0 + dist($1.0, $1.1) } }
    private static func turn(_ p: P, _ t: Double) -> P { P(x: p.x * cos(t) + p.y * sin(t), y: p.y * cos(t) - p.x * sin(t)) }
    private static func nearest(_ p: P, _ pts: ArraySlice<P>) -> Double { pts.map { dist(p, $0) }.min() ?? .infinity }

    private static func box(_ pts: [P]) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
        return (xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
    }

    private static func toSegment(_ p: P, _ a: P, _ b: P) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
        let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    /// Where a straight line from `a` should end for a tip at `b`: on the level, the upright or a 45° when within 3° of one.
    static func aim(_ a: P, _ b: P) -> P {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y), angle = atan2(dy, dx)
        let even = (angle / (.pi / 4)).rounded() * (.pi / 4)
        if abs(angle - even) > snapAngle { return b }
        let along = hypot(dx, dy) * cos(angle - even)
        return P(x: Double(a.x) + along * cos(even), y: Double(a.y) + along * sin(even))
    }

    private static func resample(_ pts: [P], _ n: Int) -> [P] {
        let step = length(pts) / Double(n - 1)
        var out = [pts[0]], need = step
        for i in 1..<pts.count {
            var a = pts[i - 1], d = dist(a, pts[i])
            while d >= need && d > 0 {
                a = P(x: a.x + (pts[i].x - a.x) * need / d, y: a.y + (pts[i].y - a.y) * need / d)
                out.append(a)
                d -= need
                need = step
            }
            need -= d
        }
        if out.count < n { out.append(pts[pts.count - 1]) }
        return out
    }

    private static func tilt(_ pts: [P]) -> (t: Double, w: Double, h: Double) {
        func sides(_ t: Double) -> (Double, Double) { let b = box(pts.map { turn($0, t) }); return (b.x1 - b.x0, b.y1 - b.y0) }
        func area(_ t: Double) -> Double { let s = sides(t); return s.0 * s.1 }
        var best = 0.0
        for (from, to, by) in [(0.0, 90.0, 1.0), (-1.0, 1.0, 0.1)] {
            let middle = best
            var deg = from
            while deg <= to {
                let t = middle + deg * .pi / 180
                if area(t) < area(best) { best = t }
                deg += by
            }
        }
        let s = sides(best)
        return (best, s.0, s.1)
    }

    private struct Candidate {
        let around: Double
        let points: [P]
        let far: (P) -> Double
    }

    private static func ellipse(_ pts: [P], _ t: Double) -> Candidate {
        let seen = pts.map { turn($0, t) }, b = box(seen)
        let cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2
        var rx = (b.x1 - b.x0) / 2, ry = (b.y1 - b.y0) / 2
        let mean = seen.reduce(0.0) { $0 + hypot((Double($1.x) - cx) / rx, (Double($1.y) - cy) / ry) } / Double(seen.count)
        rx *= mean
        ry *= mean
        if abs(rx - ry) < round * max(rx, ry) { rx = (rx + ry) / 2; ry = rx }
        let around = Double.pi * (3 * (rx + ry) - ((3 * rx + ry) * (rx + 3 * ry)).squareRoot())
        let n = max(24, 4 * Int((around / step / 4).rounded(.up)))
        var points: [P] = []
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * .pi
            points.append(turn(P(x: cx + rx * cos(a), y: cy + ry * sin(a)), -t))
        }
        points.append(points[0])
        let frx = rx, fry = ry
        return Candidate(around: around, points: points) { p in
            let q = turn(p, t), r = hypot(Double(q.x) - cx, Double(q.y) - cy), scaled = hypot((Double(q.x) - cx) / frx, (Double(q.y) - cy) / fry)
            return scaled > 0 ? abs(r - r / scaled) : min(frx, fry)
        }
    }

    /// A closed shape with straight sides; a corner is there twice, so the line turns sharply at it.
    private static func polygon(_ corners: [P]) -> Candidate {
        let sides = corners.indices.map { (corners[$0], corners[($0 + 1) % corners.count]) }
        var points: [P] = []
        for (a, b) in sides {
            let n = max(1, Int((dist(a, b) / step).rounded()))
            for i in 0...n { points.append(P(x: a.x + (b.x - a.x) * Double(i) / Double(n), y: a.y + (b.y - a.y) * Double(i) / Double(n))) }
        }
        return Candidate(around: length(corners + [corners[0]]), points: points) { p in sides.map { toSegment(p, $0.0, $0.1) }.min() ?? 0 }
    }

    private static func rect(_ pts: [P], _ t: Double) -> Candidate {
        let seen = pts.map { turn($0, t) }, b = box(seen)
        let edges = [b.x0, b.y0, b.x1, b.y1]
        var sum = [0.0, 0, 0, 0], count = [0.0, 0, 0, 0]
        for p in seen {
            let gaps = [Double(p.x) - b.x0, Double(p.y) - b.y0, b.x1 - Double(p.x), b.y1 - Double(p.y)]
            let side = gaps.firstIndex(of: gaps.min() ?? 0) ?? 0
            sum[side] += side % 2 == 1 ? Double(p.y) : Double(p.x)
            count[side] += 1
        }
        let e = (0..<4).map { count[$0] > 0 ? sum[$0] / count[$0] : edges[$0] }
        return polygon([P(x: e[0], y: e[1]), P(x: e[2], y: e[1]), P(x: e[2], y: e[3]), P(x: e[0], y: e[3])].map { turn($0, -t) })
    }

    private static func lineThrough(_ pts: [P]) -> (at: P, dir: P) {
        let n = Double(pts.count)
        let cx = pts.reduce(0.0) { $0 + Double($1.x) } / n, cy = pts.reduce(0.0) { $0 + Double($1.y) } / n
        var xx = 0.0, yy = 0.0, xy = 0.0
        for p in pts { xx += pow(Double(p.x) - cx, 2); yy += pow(Double(p.y) - cy, 2); xy += (Double(p.x) - cx) * (Double(p.y) - cy) }
        let t = atan2(2 * xy, xx - yy) / 2
        return (P(x: cx, y: cy), P(x: cos(t), y: sin(t)))
    }

    private static func triangle(_ pts: [P]) -> Candidate {
        var most = -1.0, at = (0, 1, 2)
        for i in 0..<pts.count { for j in (i + 1)..<max(i + 1, pts.count) { for k in (j + 1)..<max(j + 1, pts.count) {
            let area = abs((pts[j].x - pts[i].x) * (pts[k].y - pts[i].y) - (pts[k].x - pts[i].x) * (pts[j].y - pts[i].y))
            if area > most { most = area; at = (i, j, k) }
        } } }
        let (i, j, k) = at
        let lines = [Array(pts[i...j]), Array(pts[j...k]), Array(pts[k...]) + Array(pts[...i])].map { side -> (at: P, dir: P) in
            let trim = side.count / 5
            return lineThrough(side.count - 2 * trim > 2 ? Array(side[trim..<(side.count - trim)]) : [side[0], side[side.count - 1]])
        }
        var corners = [(lines[2], lines[0], pts[i]), (lines[0], lines[1], pts[j]), (lines[1], lines[2], pts[k])].map { a, b, rough -> P in
            let cross = a.dir.x * b.dir.y - a.dir.y * b.dir.x
            if abs(cross) < 0.1 { return rough }
            let along = ((b.at.x - a.at.x) * b.dir.y - (b.at.y - a.at.y) * b.dir.x) / cross
            return P(x: a.at.x + along * a.dir.x, y: a.at.y + along * a.dir.y)
        }
        let mid = P(x: (corners[0].x + corners[1].x + corners[2].x) / 3, y: (corners[0].y + corners[1].y + corners[2].y) / 3)
        let offs = (0..<3).map { n -> Double in
            let c = corners[n], next = corners[(n + 1) % 3], angle = atan2(Double(next.y - c.y), Double(next.x - c.x))
            return angle - (angle / (.pi / 2)).rounded() * (.pi / 2)
        }.sorted { abs($0) < abs($1) }
        if abs(offs[0]) < upright / 2 * .pi / 180 {
            corners = corners.map { c in
                let q = turn(P(x: c.x - mid.x, y: c.y - mid.y), offs[0])
                return P(x: q.x + mid.x, y: q.y + mid.y)
            }
        }
        return polygon(corners)
    }

    /// The clean shape's points, or nil for anything else (handwriting, a scribble, an open curve).
    /// `min`: the smallest line worth straightening; a closed shape must be half as big again.
    static func recognise(_ points: [P], min least: Double = 24) -> [P]? {
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        let chord = dist(first, last)
        if chord >= least {
            let ux = Double(last.x - first.x) / chord, uy = Double(last.y - first.y) / chord, bend = max(lineBend * chord, least / 12)
            var reached = 0.0, straight = true
            for p in points {
                let along = Double(p.x - first.x) * ux + Double(p.y - first.y) * uy, off = abs(Double(p.x - first.x) * uy - Double(p.y - first.y) * ux)
                if off > bend || along < reached - 2 * bend || along > chord + bend { straight = false; break }
                reached = max(reached, along)
            }
            if straight {
                let end = aim(first, last), n = max(2, Int(dist(first, end) / step))
                return (0...n).map { P(x: first.x + (end.x - first.x) * Double($0) / Double(n), y: first.y + (end.y - first.y) * Double($0) / Double(n)) }
            }
        }
        guard length(points) > 0 else { return nil }
        let pts = resample(points, samples), b = box(pts), drawn = length(pts)
        let size = (b.x1 - b.x0 + b.y1 - b.y0) / 2, third = Int((Double(pts.count) / 3).rounded(.up))
        if size < least * 1.5 || pts.count < 6 { return nil }
        if min(nearest(last, pts.prefix(third)), nearest(first, pts.suffix(third))) > close * size { return nil }
        let tl = tilt(pts)
        if min(tl.w, tl.h) < sliver * max(tl.w, tl.h) { return nil }
        let three = triangle(pts), limit = Int(Double(pts.count) * 0.9)
        func judge(_ c: Candidate) -> (c: Candidate, mean: Double, worst: Double) {
            let off = pts.map(c.far).sorted()
            return (c, off.reduce(0, +) / Double(off.count), off[min(limit, off.count - 1)])
        }
        let quarter = Double.pi / 2, lean = abs(tl.t - (tl.t / quarter).rounded() * quarter) * 180 / .pi
        for t in lean < upright ? [0, tl.t] : [tl.t] {
            guard let best = [ellipse(pts, t), rect(pts, t), three].map(judge).min(by: { $0.mean < $1.mean }) else { continue }
            let turns = drawn / best.c.around
            if best.mean <= fit * size && best.worst <= fitWorst * size && turns > 0.8 && turns < 1.4 { return best.c.points }
        }
        return nil
    }
}
