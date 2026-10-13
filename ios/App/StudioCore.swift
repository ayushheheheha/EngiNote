import Foundation
import CoreGraphics
import CoreMedia

// Studio: what is done to a recording after it is made, when the user asks (Studio.swift is the screen,
// StudioRender.swift does the work). Nothing in the Studio files except Studio.swift uses UIKit, so that
// they can be built and tried out on a Mac as well (ios/StudioTests, run by .github/workflows/studio.yml).

/// What the recorder notes about a recording while it is made, kept beside the movie so that Studio can use
/// it later. It is tiny: the pen's path is about twenty numbers a second while writing, and nothing otherwise.
struct Sidecar: Codable {
    var version = 1
    /// The wall clock (ms since 1970) when the movie's first frame arrived. The page's times are on that clock too.
    var startedAt: Double = 0
    /// [from, to] on the wall clock: stretches that were paused, and so are not in the movie.
    var pauses: [[Double]] = []
    /// x, y, width, height in screen points: the part of the screen the movie shows.
    var window: [Double] = []
    /// [wall clock ms, u, v, touching]: where the pen was, u and v as fractions across the movie's picture (0 to 1,
    /// from the top left); touching 1 if it was on the glass, 0 if hovering.
    var pen: [[Double]] = []
    /// [wall clock ms, x, y, width, height, corner radius] in screen points: where the camera bubble was from then on.
    /// Width 0: it was switched off.
    var bubble: [[Double]] = []
    /// How the voice got into the movie: [pieces written, pieces that had to wait their turn, pieces lost, breaks
    /// in its timing]. nil: recorded before this was counted.
    var sound: [Int]?

    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    /// Where the sidecar of a movie is kept: out of sight of the Files app, which shows the Documents folder.
    static func url(for movie: URL) -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let folder = support.appendingPathComponent("Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(movie.lastPathComponent + ".json")
    }

    func save(for movie: URL) {
        guard let place = Sidecar.url(for: movie), let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: place, options: .atomic)
    }

    static func load(for movie: URL) -> Sidecar? {
        guard let place = url(for: movie), let data = try? Data(contentsOf: place), let found = try? JSONDecoder().decode(Sidecar.self, from: data),
              found.startedAt > 0 else { return nil }
        return found
    }

    /// The sound count in words, for the Studio screen; nil if it was not counted.
    var soundReport: String? {
        guard let sound = sound, sound.count == 4 else { return nil }
        if sound[0] == 0 { return "Sound check: no sound reached this recording." }
        if sound[2] == 0 && sound[3] == 0 { return "Sound check: all \(sound[0]) pieces of sound were written, none lost." }
        return "Sound check: \(sound[2]) of \(sound[0] + sound[2]) pieces of sound were lost and the microphone's timing broke \(sound[3]) times. Places where the voice drops or stutters may come from that."
    }

    /// Seconds into the movie for a wall-clock time; nil if that was before it began or while it was paused.
    func videoTime(_ epoch: Double) -> Double? {
        var t = epoch - startedAt
        if t < 0 { return nil }
        for pause in pauses where pause.count == 2 {
            if epoch >= pause[1] { t -= pause[1] - pause[0] } else if epoch > pause[0] { return nil }
        }
        return max(0, t) / 1000
    }

    /// The pen's samples as (seconds into the movie, u, v, touching), in time order.
    func penPath() -> [(t: Double, u: Double, v: Double, down: Bool)] {
        pen.compactMap { p in
            guard p.count == 4, let t = videoTime(p[0]) else { return nil }
            return (t, p[1], p[2], p[3] > 0.5)
        }.sorted { $0.t < $1.t }
    }

    /// The camera bubble as it was `t` seconds in, as fractions of the movie's picture (x, y, width, height from
    /// the top left) and its corner radius as a fraction of the picture's width; nil if there was none then.
    func bubble(at t: Double) -> (rect: CGRect, radius: Double)? {
        guard window.count == 4, window[2] > 0, window[3] > 0 else { return nil }
        var found: [Double]?
        for entry in bubble where entry.count == 6 {
            guard let at = videoTime(entry[0]), at <= t else { continue }
            found = entry
        }
        guard let b = found, b[3] > 0, b[4] > 0 else { return nil }
        let rect = CGRect(x: (b[1] - window[0]) / window[2], y: (b[2] - window[1]) / window[3], width: b[3] / window[2], height: b[4] / window[3])
        return (rect, b[5] / window[2])
    }

    /// Whether the bubble was ever in the picture.
    var hadBubble: Bool { bubble.contains { $0.count == 6 && $0[3] > 0 } }
}

/// Where the virtual camera is, at every sixtieth of a second: the middle of what it shows (fractions of the
/// picture, from the top left) and how far it is zoomed in (1: all of it). Made from the pen's path.
///
/// The camera goes where the writing is: for each moment it takes the box round the strokes of the last couple of
/// seconds and the next half second (it can look ahead, the recording being over), zooms until that box fits with
/// room round it, and centres on it. Small movements of the box leave it where it is, so the picture does not
/// wander with every word; a box that has moved far, or grown or shrunk much, moves it. When the pen has been still
/// for a while it eases back out to the whole picture. All of it is smoothed by a critically damped spring, so every
/// movement starts and ends gently and nothing overshoots.
struct ZoomPlan {
    static let rate = 60.0
    private(set) var cx: [Float] = []
    private(set) var cy: [Float] = []
    private(set) var zoom: [Float] = []

    struct Tuning {
        var maxZoom = 1.8        // the closest it gets in
        var past = 1.3           // seconds of writing before a moment that the camera keeps in view
        var future = 0.7         // and after it, which it moves towards early
        var linger = 2.4         // seconds of stillness before it eases out
        var padding = 0.10       // room round the writing, as a fraction of the picture, at least
        var spring = 5.5         // radians a second: how brisk the camera is (about 0.9 s to settle)
    }

    /// The shape of the picture the camera fills (`canvas`, width over height) from a source (`source`, likewise):
    /// the biggest part of the source with the canvas's shape, as fractions of its width and height.
    static func base(canvas: Double, source: Double) -> (w: Double, h: Double) {
        canvas <= source ? (canvas / source, 1) : (1, source / canvas)
    }

    init(path: [(t: Double, u: Double, v: Double, down: Bool)], duration: Double, canvas: Double, source: Double, tuning: Tuning = Tuning()) {
        let frames = max(1, Int((duration * ZoomPlan.rate).rounded(.up)))
        let base = ZoomPlan.base(canvas: canvas, source: source)
        let writing = path.filter { $0.down }
        cx.reserveCapacity(frames); cy.reserveCapacity(frames); zoom.reserveCapacity(frames)

        // What the camera is held on: updated only when the writing has really moved.
        var held = (x: 0.5, y: 0.5, z: 1.0)
        var lastActive = -Double.infinity
        // The spring: position and speed for x, y and ln z.
        var pos = (x: 0.5, y: 0.5, z: 0.0), speed = (x: 0.0, y: 0.0, z: 0.0)
        let w = tuning.spring, dt = 1 / ZoomPlan.rate
        var lo = 0, hi = 0 // the samples from `lo` up to (not including) `hi` are in the window

        for i in 0..<frames {
            let t = Double(i) * dt
            while hi < writing.count, writing[hi].t <= t + tuning.future { hi += 1 }
            while lo < hi, writing[lo].t < t - tuning.past { lo += 1 }
            if lo < hi {
                lastActive = t
                var x0 = 1.0, x1 = 0.0, y0 = 1.0, y1 = 0.0
                for k in lo..<hi {
                    x0 = min(x0, writing[k].u); x1 = max(x1, writing[k].u)
                    y0 = min(y0, writing[k].v); y1 = max(y1, writing[k].v)
                }
                let room = tuning.padding
                let zWanted = min(tuning.maxZoom, max(1, min(base.w / (x1 - x0 + 2 * room), base.h / (y1 - y0 + 2 * room))))
                let want = (x: (x0 + x1) / 2, y: (y0 + y1) / 2, z: zWanted)
                // Move only for writing that has gone well outside the view, or a different closeness.
                let cropW = base.w / held.z, cropH = base.h / held.z
                let outside = abs(want.x - held.x) > 0.15 * cropW || abs(want.y - held.y) > 0.15 * cropH
                let closer = abs(log(want.z / held.z)) > 0.12
                if held.z == 1 && want.z > 1.05 || outside || closer { held = want }
            } else if t - lastActive > tuning.linger {
                held = (0.5, 0.5, 1)
            }
            // The spring chases `held`.
            let target = (x: held.x, y: held.y, z: log(held.z))
            speed.x += (w * w * (target.x - pos.x) - 2 * w * speed.x) * dt; pos.x += speed.x * dt
            speed.y += (w * w * (target.y - pos.y) - 2 * w * speed.y) * dt; pos.y += speed.y * dt
            speed.z += (w * w * (target.z - pos.z) - 2 * w * speed.z) * dt; pos.z += speed.z * dt
            cx.append(Float(pos.x)); cy.append(Float(pos.y)); zoom.append(Float(max(0, pos.z)))
        }
    }

    /// The camera `t` seconds in: its middle and its zoom (1 or more), from the closest frame, blended with the next.
    func at(_ t: Double) -> (x: Double, y: Double, z: Double) {
        guard !cx.isEmpty else { return (0.5, 0.5, 1) }
        let f = min(max(t * ZoomPlan.rate, 0), Double(cx.count - 1))
        let i = Int(f), j = min(i + 1, cx.count - 1), k = f - Double(i)
        let mix = { (a: [Float]) in Double(a[i]) * (1 - k) + Double(a[j]) * k }
        return (mix(cx), mix(cy), exp(mix(zoom)))
    }

    /// What of the source the camera shows at `t`, as fractions from the top left: the crop for a canvas of this shape.
    func crop(at t: Double, canvas: Double, source: Double) -> CGRect {
        let view = at(t), base = ZoomPlan.base(canvas: canvas, source: source)
        let w = base.w / view.z, h = base.h / view.z
        return CGRect(x: min(max(view.x - w / 2, 0), 1 - w), y: min(max(view.y - h / 2, 0), 1 - h), width: w, height: h)
    }
}

/// Times the microphone's sound for the movie. Each piece arrives with the device's time for its first sample, and
/// those times wobble a little; written as they come, the pieces could overlap or leave hairline gaps. So a piece
/// that arrives about when the one before it ended is placed exactly there, to the sample, and only a real break
/// (the microphone stopped for a moment) moves the sound to the device's time again.
struct SoundClock {
    private var anchor: Int64 = 0 // the sample (counted at `rate` from the device's time zero) the unbroken run began on
    private var count: Int64 = 0  // samples placed since
    private var rate = 0.0
    private(set) var breaks = 0
    /// How far a piece may be from where the last one ended and still be joined to it.
    static let slack = 0.02 // seconds

    /// Where a piece of `frames` samples at `rate` a second, said to start at `host`, goes in the movie.
    mutating func place(host: CMTime, frames: Int, rate: Double) -> CMTime {
        let said = Int64((CMTimeGetSeconds(host) * rate).rounded())
        if self.rate != rate || abs(Double(said - (anchor + count))) > SoundClock.slack * rate {
            if self.rate != 0 { breaks += 1 }
            anchor = said
            count = 0
            self.rate = rate
        }
        let start = CMTime(value: anchor + count, timescale: CMTimeScale(rate))
        count += Int64(frames)
        return start
    }
}
