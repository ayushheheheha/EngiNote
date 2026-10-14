import AVFoundation
import Foundation

// The intro and outro put straight onto a recording, without making the video again: the recording's own
// picture and sound are copied as they are, so an hour's lecture takes about as long as copying its file.
// (Studio's switches draw every frame anew, which they must when the picture itself changes.)
//
// For a copy to be possible the two clips have to be the recording's kind of movie: its size, H.264, its
// kind of sound. They are made so once (a few seconds) and kept in the caches folder.
//
// So that the intro does not jump to the recording, nor the recording to the outro, the change goes through black,
// as it does in Studio: the clip fades, and between it and the recording stands half a second of the recording's
// first (or last) frame coming up out of black (or going down into it). The recording's own frames are still
// copied untouched, and taking the intro and outro off gives back exactly the recording.
//
// No UIKit, like the other Studio files, so that ios/StudioTests can try it on a Mac.
enum StudioWrap {
    /// How long the intro put in a recording and the outro after it are, in seconds, and where the intro begins
    /// (`at`, seconds into the file; nil or 0: the intro is first). `lead` is the whole of what stands there: the
    /// recording going down into black (if it had begun), the intro, and the recording coming up out of black.
    /// Kept beside the recording's sidecar while it has them: it is what says that it does, and where to cut to take them off.
    struct Marks: Codable {
        var lead: Double
        var tail: Double
        var at: Double?
    }

    private static func marksURL(for movie: URL) -> URL? {
        Sidecar.url(for: movie)?.deletingPathExtension().appendingPathExtension("wrap.json")
    }

    /// nil: the recording has no intro and outro put on it this way.
    static func marks(for movie: URL) -> Marks? {
        guard let url = marksURL(for: movie), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Marks.self, from: data)
    }

    private static func setMarks(_ marks: Marks?, for movie: URL) {
        guard let url = marksURL(for: movie) else { return }
        if let marks = marks, let data = try? JSONEncoder().encode(marks) { try? data.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
    }

    /// The recording is being deleted: so is what was noted about it here.
    static func forget(_ movie: URL) { setMarks(nil, for: movie) }

    // MARK: Putting them on, taking them off

    /// Put `intro` into the recording `introAt` seconds in (0: before it; what is said before it plays, then the intro,
    /// then the rest) and `outro` after it, in the recording's own file. If it cannot be done the recording is left
    /// as it was, and the reason is thrown.
    static func add(to movie: URL, intro: URL?, outro: URL?, introAt: Double = 0) async throws {
        guard marks(for: movie) == nil, intro != nil || outro != nil else { return }
        let asset = AVURLAsset(url: movie)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw StudioRender.error("there is no picture in this recording") }
        let size = try await video.load(.naturalSize), turn = try await video.load(.preferredTransform)
        // ponytail: a recording stored turned on its side cannot take an upright clip into the same track. Studio can
        // (it draws every frame); clips made turned the same way, if such recordings turn out to be common.
        guard turn.isIdentity else { throw StudioRender.error("this recording is stored on its side. Studio can add them instead") }

        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioRender.error("the video could not be put together")
        }
        var cursor = CMTime.zero
        /// The next `length` of the movie is `piece`, from `start` in it.
        func append(_ piece: AVAsset, _ length: CMTime, from start: CMTime = .zero) async throws {
            let range = CMTimeRange(start: start, duration: length)
            if let v = try await piece.loadTracks(withMediaType: .video).first { try picture.insertTimeRange(range, of: v, at: cursor) }
            if let a = try await piece.loadTracks(withMediaType: .audio).first { try sound.insertTimeRange(range, of: a, at: cursor) }
            cursor = CMTimeAdd(cursor, length)
        }
        /// A movie made the recording's kind; its length in whole frames, so that what follows begins exactly on one.
        func piece(_ url: URL) async throws -> Double {
            let made = AVURLAsset(url: url)
            guard let v = try await made.loadTracks(withMediaType: .video).first else { return 0 }
            let length = CMTime(value: Int64((try await v.load(.timeRange).duration.seconds * 60 + 0.001).rounded(.down)), timescale: 60)
            try await append(made, length)
            return length.seconds
        }
        var bridges: [URL] = [] // made for this recording alone, and needed only until the copy is done
        defer { bridges.forEach { try? FileManager.default.removeItem(at: $0) } }
        var lead = 0.0, tail = 0.0
        // Where the intro goes: on a whole frame, and not so late that nothing is left of the recording after it.
        let total = try await asset.load(.duration)
        let cut = intro == nil ? CMTime.zero : CMTime(value: Int64((min(max(0, introAt), max(0, total.seconds - 1)) * 60).rounded(.down)), timescale: 60)
        let mid = cut.seconds > 0 // something is said before the intro: the recording runs up to it, goes down into black, the intro plays, and the rest comes up out of black
        if mid { try await append(asset, cut) }
        if let intro = intro {
            if mid {
                bridges.append(try await bridge(video, size: size, end: true, at: cut))
                lead += try await piece(bridges[bridges.count - 1])
            }
            lead += try await piece(try await matched(intro, size: size, fadeIn: mid ? StudioRender.dip.clip : 0, fadeOut: StudioRender.dip.clip))
            bridges.append(try await bridge(video, size: size, end: false, at: mid ? cut : nil))
            lead += try await piece(bridges[bridges.count - 1])
        }
        try await append(asset, CMTimeSubtract(total, cut), from: cut)
        if let outro = outro {
            bridges.append(try await bridge(video, size: size, end: true))
            tail += try await piece(bridges[bridges.count - 1])
            tail += try await piece(try await matched(outro, size: size, fadeIn: StudioRender.dip.clip))
        }
        if sound.segments.isEmpty { composition.removeTrack(sound) }

        try await replace(movie) { try await copy(composition, range: nil, to: $0) }
        setMarks(Marks(lead: lead, tail: tail, at: mid ? cut.seconds : nil), for: movie)
    }

    /// Take the intro and outro off again, in the recording's own file.
    static func remove(from movie: URL) async throws {
        guard marks(for: movie) != nil else { return }
        try await replace(movie) { try await bare(movie, to: $0) }
        setMarks(nil, for: movie)
    }

    /// The recording without its intro and outro, as a new movie at `url`.
    static func bare(_ movie: URL, to url: URL) async throws {
        guard let marks = marks(for: movie) else { throw StudioRender.error("this recording has no intro and outro to take off") }
        let asset = AVURLAsset(url: movie)
        let length = CMTimeSubtract(try await asset.load(.duration), CMTime(seconds: marks.lead + marks.tail, preferredTimescale: 600))
        guard length.seconds > 0 else { throw StudioRender.error("this recording is shorter than its intro and outro") }
        guard let at = marks.at, at > 0 else { // the intro first: the recording is what lies between the intro and the outro
            try await copy(asset, range: CMTimeRange(start: CMTime(seconds: marks.lead, preferredTimescale: 600), duration: length), to: url)
            return
        }
        // The intro part-way in: the recording is what is before it and what is after it, joined up again.
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let video = try await asset.loadTracks(withMediaType: .video).first else { throw StudioRender.error("the video could not be put together") }
        let before = CMTime(seconds: at, preferredTimescale: 600), after = CMTime(seconds: at + marks.lead, preferredTimescale: 600)
        var sources: [(AVAssetTrack, AVMutableCompositionTrack)] = [(video, picture)]
        if let heard = try await asset.loadTracks(withMediaType: .audio).first { sources.append((heard, sound)) }
        for (from, into) in sources {
            try into.insertTimeRange(CMTimeRange(start: .zero, duration: before), of: from, at: .zero)
            try into.insertTimeRange(CMTimeRange(start: after, duration: CMTimeSubtract(length, before)), of: from, at: before)
        }
        if sound.segments.isEmpty { composition.removeTrack(sound) }
        try await copy(composition, range: nil, to: url)
    }

    /// Make a new movie with `make` and, if that worked, put it in the recording's place.
    private static func replace(_ movie: URL, with make: (URL) async throws -> Void) async throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("wrap-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: made) }
        try await make(made)
        guard FileManager.default.fileExists(atPath: movie.path) else { throw StudioRender.error("the recording was deleted meanwhile") }
        _ = try FileManager.default.replaceItemAt(movie, withItemAt: made)
    }

    /// Write `asset` (or `range` of it) to `url` as it is: nothing is drawn or encoded again.
    private static func copy(_ asset: AVAsset, range: CMTimeRange?, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw StudioRender.error("the video could not be copied") }
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = .mov
        if let range = range { session.timeRange = range }
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw session.error ?? StudioRender.error("the video could not be copied")
        }
    }

    // MARK: The clips, made the recording's kind

    /// Half a second of the recording's first frame coming up out of black (`end`: of its last, going down into
    /// black), as a movie of its own: what stands between a clip and the recording.
    /// `at`: seconds into the recording where the intro goes, for a clip put part-way in; nil: at its start (or end).
    private static func bridge(_ video: AVAssetTrack, size: CGSize, end: Bool, at: CMTime? = nil) async throws -> URL {
        let whole = try await video.load(.timeRange), one = CMTime(value: 1, timescale: 60)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioRender.error("the video could not be put together") }
        // One frame's worth of the recording, drawn out to the length of the fade: the first after the place, or the last before it.
        let place = at.map { CMTimeAdd(whole.start, $0) } ?? (end ? whole.end : whole.start)
        try track.insertTimeRange(CMTimeRange(start: end ? CMTimeSubtract(place, one) : place, duration: one), of: video, at: .zero)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: StudioRender.dip.recording, preferredTimescale: 600))
        track.scaleTimeRange(CMTimeRange(start: .zero, duration: one), toDuration: range.duration)
        let composed = AVMutableVideoComposition()
        composed.customVideoCompositorClass = StudioCompositor.self
        composed.frameDuration = one
        composed.renderSize = size
        let job = StudioJob(sidecar: nil, plan: nil, title: "", canvas: size, sourceSize: size)
        composed.instructions = [StudioInstruction(range: range, kind: .clip, job: job, trackID: track.trackID, shift: 0, fadeIn: end ? 0 : range.duration.seconds, fadeOut: end ? range.duration.seconds : 0)]
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString).mov")
        try await StudioRender.write(composition, composed, to: made, size: size, bitRate: StudioRender.bitRate(size), length: range.duration.seconds, cancel: StudioCancel()) { _ in }
        return made
    }

    /// `clip` as a movie `size` large, in the picture and sound a recording has, fading up out of black over
    /// `fadeIn` seconds and down into it over `fadeOut`: made once, then kept (in the caches folder, which the
    /// system may empty: then it is made again).
    static func matched(_ clip: URL, size: CGSize, fadeIn: Double = 0, fadeOut: Double = 0) async throws -> URL {
        let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("StudioClips", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Its size in bytes is in the name: a new intro in a new build is a new file, and is made anew.
        let bytes = (try? clip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let kept = folder.appendingPathComponent("\(clip.deletingPathExtension().lastPathComponent)-\(Int(size.width))x\(Int(size.height))-\(bytes)-\(fadeIn)-\(fadeOut).mov")
        if FileManager.default.fileExists(atPath: kept.path) { return kept }

        let asset = AVURLAsset(url: clip)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw StudioRender.error("the intro or outro has no picture") }
        let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioRender.error("the intro or outro could not be read") }
        try track.insertTimeRange(range, of: video, at: .zero)
        if let a = try await asset.loadTracks(withMediaType: .audio).first {
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(range, of: a, at: .zero)
        }
        let composed = AVMutableVideoComposition()
        composed.customVideoCompositorClass = StudioCompositor.self
        composed.frameDuration = CMTime(value: 1, timescale: 60)
        composed.renderSize = size
        let job = StudioJob(sidecar: nil, plan: nil, title: "", canvas: size, sourceSize: size)
        composed.instructions = [StudioInstruction(range: range, kind: .clip, job: job, trackID: track.trackID, shift: 0, fadeIn: fadeIn, fadeOut: fadeOut)]
        // Under another name until it is whole: a half-made one must never be taken for the clip.
        let making = folder.appendingPathComponent("making-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: making) }
        try await StudioRender.write(composition, composed, to: making, size: size, bitRate: StudioRender.bitRate(size), length: range.duration.seconds, cancel: StudioCancel()) { _ in }
        try? FileManager.default.removeItem(at: kept)
        try FileManager.default.moveItem(at: making, to: kept)
        return kept
    }
}
