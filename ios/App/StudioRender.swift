import AVFoundation
import CoreImage
import Foundation

/// What the user chose in Studio.
struct StudioOptions {
    var autoZoom = true
    var polish = true
    var intro = true
    /// Seconds into the recording where the intro goes (0: before it). What is said before it plays first.
    var introAt = 0.0
    var outro = true
    /// Also make a vertical short of `shortLength` seconds starting at `shortStart`.
    var short = false
    var shortStart = 0.0
    var shortLength = 60.0
}

/// Stops a render that is under way.
final class StudioCancel {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

enum StudioRender {
    struct Made {
        var files: [URL] = []
        /// Things the user should know: what could not be done and why.
        var notes: [String] = []
    }

    /// The change from the intro to the recording, and from the recording to the outro, goes through black: the clip
    /// fades over `clip` seconds and the recording over `recording`.
    static let dip = (clip: 0.3, recording: 0.5)

    static func error(_ text: String) -> NSError { NSError(domain: "EngiNote", code: 30, userInfo: [NSLocalizedDescriptionKey: text]) }

    /// "Thermodynamics 2026-10-11 14.03.22" -> "Thermodynamics": a recording's name without the time it was made.
    static func title(of movie: URL) -> String {
        var name = movie.deletingPathExtension().lastPathComponent
        if let range = name.range(of: #" \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}$"#, options: .regularExpression) { name.removeSubrange(range) }
        return name.isEmpty ? "EngiKode" : name
    }

    /// A free name in `folder`: "<base> <suffix>.mov", then "<base> <suffix> 2.mov", ...
    static func freeName(in folder: URL, base: String, suffix: String) -> URL {
        var url = folder.appendingPathComponent("\(base) \(suffix).mov")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(suffix) \(n).mov")
            n += 1
        }
        return url
    }

    /// Make the video(s). `intro` and `outro` are the clips to put before and after (nil: none). `progress` is told how far
    /// it is (0 to 1) and what is being done. Written into `folder` as new recordings; the original is not touched.
    static func run(movie: URL, options: StudioOptions, intro: URL?, outro: URL?, folder: URL, cancel: StudioCancel,
                    progress: @escaping (Double, String) -> Void) async throws -> Made {
        var made = Made()
        let asset = AVURLAsset(url: movie)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw error("There is no picture in this recording.") }
        let duration = try await asset.load(.duration)
        let natural = try await video.load(.naturalSize), transform = try await video.load(.preferredTransform)
        let upright = natural.applying(transform)
        let source = CGSize(width: abs(upright.width).rounded(), height: abs(upright.height).rounded())
        guard source.width > 0, source.height > 0, duration.seconds > 0.5 else { throw error("This recording is too short.") }
        let title = StudioRender.title(of: movie), base = movie.deletingPathExtension().lastPathComponent
        let sidecar = Sidecar.load(for: movie)
        let path = sidecar?.penPath() ?? []

        // Plan the work: shares of the progress bar.
        let wantsShort = options.short
        let wantsMain = true
        let shares: [(name: String, weight: Double)] = [("Polishing the voice", options.polish ? 1 : 0), ("Making the video", wantsMain ? 5 : 0), ("Making the short", wantsShort ? 3 : 0)]
        let totalWeight = shares.reduce(0) { $0 + $1.weight }
        var before = 0.0
        func span(_ index: Int) -> (Double) -> Void {
            let from = before / totalWeight, to = (before + shares[index].weight) / totalWeight
            return { progress(from + (to - from) * min(1, max(0, $0)), shares[index].name) }
        }
        func advance(_ index: Int) { before += shares[index].weight }

        // The voice, once for both videos.
        var voice: AVURLAsset?
        if options.polish {
            let report = span(0)
            if let done = try await AudioPolish.process(asset, progress: report) { voice = AVURLAsset(url: done.file) }
            else { made.notes.append("This recording has no sound to polish.") }
            advance(0)
        }
        if cancel.isSet { throw CancellationError() }

        if options.autoZoom, path.filter({ $0.down }).isEmpty {
            made.notes.append(sidecar == nil
                ? "Auto-zoom needs the pen's path, which only a recording made straight in EngiNote has (not one that was trimmed or edited)."
                : "The pen was not used on this recording, so there was nothing to zoom in on.")
        }

        // MARK: The main video
        if wantsMain {
            let canvas = source
            let plan = options.autoZoom && !path.isEmpty ? ZoomPlan(path: path, duration: duration.seconds, canvas: Double(canvas.width / canvas.height), source: Double(source.width / source.height)) : nil
            let job = StudioJob(sidecar: sidecar, plan: plan, title: title, canvas: canvas, sourceSize: source)
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw error("The video could not be put together.") }
            let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            var instructions: [StudioInstruction] = []
            var cursor = CMTime.zero

            func add(clip url: URL, fadeIn: Double = 0, fadeOut: Double = 0) async throws {
                let clip = AVURLAsset(url: url)
                guard let v = try await clip.loadTracks(withMediaType: .video).first else { return }
                let length = try await clip.load(.duration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: v, at: cursor)
                if let a = try await clip.loadTracks(withMediaType: .audio).first { try sound?.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: a, at: cursor) }
                instructions.append(StudioInstruction(range: CMTimeRange(start: cursor, duration: length), kind: .clip, job: job, trackID: track.trackID, shift: 0, fadeIn: fadeIn, fadeOut: fadeOut))
                cursor = CMTimeAdd(cursor, length)
            }
            let opens = options.intro && intro != nil, closes = options.outro && outro != nil
            let voiceSource = voice ?? asset
            let voiceTrack = try await voiceSource.loadTracks(withMediaType: .audio).first
            let voiceLength = min(duration, try await voiceSource.load(.duration))
            /// The next stretch of the video is the recording from `from` to `to` (its own time), with its picture and voice.
            func add(recording from: CMTime, to end: CMTime, fadeIn: Double, fadeOut: Double) throws {
                let length = CMTimeSubtract(end, from)
                guard length.seconds > 0 else { return }
                try track.insertTimeRange(CMTimeRange(start: from, duration: length), of: video, at: cursor)
                let heard = CMTimeSubtract(min(end, voiceLength), from)
                if let a = voiceTrack, heard.seconds > 0 { try sound?.insertTimeRange(CMTimeRange(start: from, duration: heard), of: a, at: cursor) }
                instructions.append(StudioInstruction(range: CMTimeRange(start: cursor, duration: length), kind: .main, job: job, trackID: track.trackID, shift: from.seconds - cursor.seconds,
                                                      transform: transform, fadeIn: fadeIn, fadeOut: fadeOut))
                cursor = CMTimeAdd(cursor, length)
            }
            // The intro goes `introAt` seconds in, on a whole frame and with a second of the recording left after it: what is said
            // before it plays first, then the intro (the picture going down into black and coming up out of it), then the rest.
            let cut = CMTime(value: Int64((min(max(0, options.introAt), max(0, duration.seconds - 1)) * 60).rounded(.down)), timescale: 60)
            if opens, let intro = intro, cut.seconds > 0 {
                try add(recording: .zero, to: cut, fadeIn: 0, fadeOut: dip.recording)
                try await add(clip: intro, fadeIn: dip.clip, fadeOut: dip.clip)
                try add(recording: cut, to: duration, fadeIn: dip.recording, fadeOut: closes ? dip.recording : 0)
            } else {
                if opens, let intro = intro { try await add(clip: intro, fadeOut: dip.clip) }
                try add(recording: .zero, to: duration, fadeIn: opens ? dip.recording : 0, fadeOut: closes ? dip.recording : 0)
            }
            if closes, let outro = outro { try await add(clip: outro, fadeIn: dip.clip) }

            let composed = AVMutableVideoComposition()
            composed.customVideoCompositorClass = StudioCompositor.self
            composed.frameDuration = CMTime(value: 1, timescale: 60)
            composed.renderSize = canvas
            composed.instructions = instructions
            let out = freeName(in: folder, base: base, suffix: "final")
            try await write(composition, composed, to: out, size: canvas, bitRate: bitRate(canvas), length: cursor.seconds, cancel: cancel, progress: span(1))
            made.files.append(out)
            advance(1)
        }
        if cancel.isSet { throw CancellationError() }

        // MARK: The short
        if wantsShort {
            let canvas = CGSize(width: 1080, height: 1920)
            let length = min(options.shortLength, max(1, duration.seconds - options.shortStart))
            var tuning = ZoomPlan.Tuning()
            tuning.maxZoom = 1.7; tuning.past = 1.0; tuning.future = 0.5; tuning.linger = 1.6
            let plan = ZoomPlan(path: path, duration: duration.seconds, canvas: 1, source: Double(source.width / source.height), tuning: tuning)
            let job = StudioJob(sidecar: sidecar, plan: plan, title: title, canvas: canvas, sourceSize: source, shortStart: options.shortStart, shortLength: length)
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw error("The short could not be put together.") }
            let range = CMTimeRange(start: CMTime(seconds: options.shortStart, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
            try track.insertTimeRange(range, of: video, at: .zero)
            let voiceSource = voice ?? asset
            if let a = try await voiceSource.loadTracks(withMediaType: .audio).first, let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try sound.insertTimeRange(range, of: a, at: .zero)
            }
            let composed = AVMutableVideoComposition()
            composed.customVideoCompositorClass = StudioCompositor.self
            composed.frameDuration = CMTime(value: 1, timescale: 60)
            composed.renderSize = canvas
            composed.instructions = [StudioInstruction(range: CMTimeRange(start: .zero, duration: range.duration), kind: .short, job: job, trackID: track.trackID, shift: options.shortStart, transform: transform)]
            let out = freeName(in: folder, base: base, suffix: "short")
            try await write(composition, composed, to: out, size: canvas, bitRate: 10_000_000, length: length, cancel: cancel, progress: span(2))
            made.files.append(out)
            advance(2)
        }
        if let voice = voice { try? FileManager.default.removeItem(at: voice.url) }
        progress(1, "Done")
        return made
    }

    static func bitRate(_ size: CGSize) -> Int { size.width * size.height > 1_500_000 ? 14_000_000 : 7_000_000 }

    // MARK: Writing the movie

    /// Draw every frame of `composition` and write it as H.264 and AAC, at 60 frames a second.
    static func write(_ composition: AVComposition, _ videoComposition: AVVideoComposition, to url: URL, size: CGSize, bitRate: Int, length: Double,
                      cancel: StudioCancel, progress: @escaping (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: composition)
        let pictures = AVAssetReaderVideoCompositionOutput(videoTracks: composition.tracks(withMediaType: .video),
                                                           videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        pictures.videoComposition = videoComposition
        pictures.alwaysCopiesSampleData = false
        guard reader.canAdd(pictures) else { throw error("The video could not be read back.") }
        reader.add(pictures)
        var sounds: AVAssetReaderAudioMixOutput?
        let audioTracks = composition.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            if reader.canAdd(output) { reader.add(output); sounds = output }
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let pictureIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2, AVVideoExpectedSourceFrameRateKey: 60,
            ] as [String: Any],
        ])
        pictureIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(pictureIn) else { throw error("This iPad cannot make a video of this kind.") }
        writer.add(pictureIn)
        var soundIn: AVAssetWriterInput?
        if sounds != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); soundIn = input }
        }

        guard writer.startWriting() else { throw writer.error ?? error("The video could not be started.") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? error("The video could not be read.") }

        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.engikode.enginote.studio.write")
            let group = DispatchGroup()
            let lock = NSLock()
            var trouble: Error?
            func fail(_ e: Error) { lock.lock(); if trouble == nil { trouble = e }; lock.unlock() }

            func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, _ seen: @escaping (CMSampleBuffer) -> Void) {
                group.enter()
                var finished = false
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData, !finished {
                        if cancel.isSet { fail(CancellationError()); finished = true; input.markAsFinished(); group.leave(); return }
                        guard let sample = output.copyNextSampleBuffer() else {
                            finished = true
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        if !input.append(sample) {
                            fail(writer.error ?? error("The video could not be written."))
                            finished = true
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        seen(sample)
                    }
                }
            }
            pump(pictureIn, pictures) { sample in progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / max(0.1, length))) }
            if let input = soundIn, let output = sounds { pump(input, output) { _ in } }

            group.notify(queue: queue) {
                if reader.status == .failed { fail(reader.error ?? error("The video could not be read.")) }
                lock.lock(); let failure = trouble; lock.unlock()
                if let failure = failure {
                    reader.cancelReading()
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    done.resume(throwing: failure)
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed { done.resume() } else {
                        try? FileManager.default.removeItem(at: url)
                        done.resume(throwing: writer.error ?? error("The video could not be finished."))
                    }
                }
            }
        }
        progress(1)
    }
}
