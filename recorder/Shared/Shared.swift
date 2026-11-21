import CoreMedia
import Foundation

// What the app and its broadcast extension share. The extension is the part iPadOS runs, in a process of its own,
// while the whole iPad is being recorded: it writes the picture (and the sound other apps play) to a movie, while
// the app, kept running in the background by its audio, writes the voice to a second file. They are joined at the end.
//
// The two processes share a folder and UserDefaults through an App Group, and nudge each other with Darwin
// notifications (which carry no data: the data is in the defaults).

enum Shared {
    /// The app's bundle id as installed: a sideloading tool adds the team to it (com.engikode.enginote.recorder.W6G293MT93).
    static let appID: String = {
        let id = Bundle.main.bundleIdentifier ?? "com.engikode.enginote.recorder"
        return id.hasSuffix(".broadcast") ? String(id.dropLast(".broadcast".count)) : id
    }()

    /// The App Group the sideloading tool gave both parts: "group." + the installed id (isideload, AltKeeper's
    /// signer, names it so); the plain name for a build signed some other way.
    static let group: String? = ["group." + appID, "group.com.engikode.enginote.recorder"].first {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }

    static var defaults: UserDefaults? { group.flatMap(UserDefaults.init(suiteName:)) }

    /// Where the two halves of a recording are written, until they are joined into one movie in the app's Documents.
    static var folder: URL? {
        guard let group, let box = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let f = box.appendingPathComponent("Raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// A recording's name, which is also its movie's: "iPad 2026-11-21 10.04.31".
    static func newID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "iPad " + f.string(from: Date())
    }

    // MARK: quality (the same choices, by the same names, as the EngiNote recorder: Recorder.swift)

    struct Quality {
        let width: Int
        let height: Int
        let bitRate: Int
    }

    static let qualities: [String: Quality] = [
        "high": Quality(width: 1920, height: 1080, bitRate: 14_000_000),
        "standard": Quality(width: 1920, height: 1080, bitRate: 7_000_000),
        "small": Quality(width: 1280, height: 720, bitRate: 3_000_000),
    ]

    // MARK: nudges between the two processes

    /// app → extension: "pause" (the pauses in the defaults changed), "stop".
    /// extension → app: "started" (the defaults' "live" names the recording), "ended" (its movie is finished).
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName((prefix + name) as CFString), nil, nil, true)
    }

    /// Run `then` on the main thread whenever the other process posts `name`.
    static func observe(_ name: String, _ then: @escaping () -> Void) {
        handlers[prefix + name] = then
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
            guard let key = name?.rawValue as String? else { return }
            DispatchQueue.main.async { Shared.handlers[key]?() }
        }, (prefix + name) as CFString, nil, .deliverImmediately)
    }

    private static let prefix = "com.engikode.enginote.recorder."
    private static var handlers: [String: () -> Void] = [:] // main thread only

    /// The app says it is alive and writing the voice itself, every half second (wall clock, seconds), so the extension
    /// leaves ReplayKit's microphone alone; without it (recording started from Control Center) the extension takes that.
    static var voiceAlive: Bool {
        guard let beat = defaults?.double(forKey: "voiceBeat") else { return false }
        return Date().timeIntervalSince1970 - beat < 3
    }
}

/// The pauses, on the device's clock (host seconds, the clock ReplayKit's frames and the microphone's sound are timed on).
/// Both writers leave out what was made during a pause and move everything after it earlier by the time paused so far,
/// each by itself but from the same numbers, so picture and voice stay together.
struct Pauses: Equatable {
    var spans: [[Double]] = [] // [from, to]
    var since: Double?         // paused right now, since then

    /// How much earlier something made at `t` goes in the movie; nil: it was made during a pause, leave it out.
    func shift(_ t: Double) -> Double? {
        if let since, t >= since { return nil }
        var total = 0.0
        for s in spans {
            if t >= s[1] { total += s[1] - s[0] } else if t >= s[0] { return nil }
        }
        return total
    }

    /// Paused, in total, up to `t`.
    func total(at t: Double) -> Double {
        spans.reduce(0) { $0 + $1[1] - $1[0] } + (since.map { max(0, t - $0) } ?? 0)
    }

    static func load(_ d: UserDefaults?) -> Pauses {
        Pauses(spans: (d?.array(forKey: "pauses") as? [[Double]]) ?? [], since: d?.object(forKey: "pausedSince") as? Double)
    }

    func save(_ d: UserDefaults?) {
        d?.set(spans, forKey: "pauses")
        if let since { d?.set(since, forKey: "pausedSince") } else { d?.removeObject(forKey: "pausedSince") }
    }
}

/// What each half knows about a recording, beside it in the shared folder as <id>.screen.json and <id>.voice.json.
struct Part: Codable {
    /// Where the half's own time 0 is on the device's clock (host seconds), after the pauses are taken out.
    var start: Double?
    /// The writer finished it properly.
    var done = false
    // The app's half only: what to do with the movie once it is joined.
    var introAt: Double?
    var wrap = false
    var shrink = false

    static func url(_ id: String, _ half: String) -> URL? { Shared.folder?.appendingPathComponent("\(id).\(half).json") }

    static func load(_ id: String, _ half: String) -> Part? {
        url(id, half).flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Part.self, from: $0) }
    }

    func save(_ id: String, _ half: String) {
        if let u = Part.url(id, half), let d = try? JSONEncoder().encode(self) { try? d.write(to: u, options: .atomic) }
    }
}

extension CMSampleBuffer {
    /// A copy timed `offset` seconds earlier.
    func moved(earlierBy offset: Double) -> CMSampleBuffer? {
        guard offset != 0 else { return self }
        let by = CMTime(seconds: offset, preferredTimescale: 1_000_000_000)
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, by)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, by) }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: self, sampleTimingEntryCount: timing.count, sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy
    }

    /// When it ends: a picture frame often does not say how long it lasts, a sixtieth of a second will do.
    var end: Double {
        let length = CMSampleBufferGetDuration(self)
        let lasts = length.isValid && length > .zero ? length.seconds : 1.0 / 60
        return CMSampleBufferGetPresentationTimeStamp(self).seconds + lasts
    }
}
