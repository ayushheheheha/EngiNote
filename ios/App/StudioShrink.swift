import AVFoundation
import Foundation

// Shrink: a recording made again as HEVC, which is about half the size of the H.264 the recorder has to write
// while it runs. The recorder is a single real-time pass, so it is generous with bits; this is a second pass
// with all the time it wants (B-frames, no deadline), the way an editor's export is.
//
// What is kept exactly: the picture's size, its frame times (so 60 frames a second stay 60, and a recording
// that only changes when the pen moves stays that way), the way it is turned, its colour tags, and the sound
// (copied as it is, not encoded again). The recording is only replaced when the new file is clearly smaller
// and plays through to the end; otherwise it is left as it was.
//
// No UIKit, like the other Studio files, so that ios/StudioTests can try it on a Mac.
enum StudioShrink {
    struct Outcome {
        let before: Int
        let after: Int
        /// The recording was replaced by the smaller one.
        let shrunk: Bool
        /// Why it was not, when it was not.
        let why: String?
    }

    /// A new file must be at most this much of the old one to be worth having.
    static let worthwhile = 0.9

    /// The recording is already HEVC (shrunk before, or made so): nothing more to gain.
    static func isShrunk(_ movie: URL) -> Bool {
        guard let track = AVURLAsset(url: movie).tracks(withMediaType: .video).first,
              let description = track.formatDescriptions.first else { return false }
        return CMFormatDescriptionGetMediaSubType(description as! CMFormatDescription) == kCMVideoCodecType_HEVC
    }

    /// Bits a second for the new picture: half of what the recording had (HEVC at half the rate looks the
    /// same as H.264), but never so little that thin handwriting smears, and never more than needed.
    static func bitRate(was: Double, width: Double, height: Double, fps: Double) -> Int {
        let perSecond = width * height * max(fps, 30)
        let floor = perSecond * 0.03, ceiling = perSecond * 0.06
        let half = was > 0 ? was * 0.5 : perSecond * 0.045
        return Int(min(ceiling, max(floor, half)))
    }

    /// Shrink the recording in its own file. Throws only for what is wrong with the work itself; "not worth it"
    /// is an outcome, and the recording is untouched then. `progress` is called with 0 to 1.
    static func shrink(_ movie: URL, cancel: StudioCancel = StudioCancel(), progress: @escaping (Double) -> Void = { _ in }) async throws -> Outcome {
        let before = size(of: movie)
        if isShrunk(movie) { return Outcome(before: before, after: before, shrunk: false, why: "it is already as small as this goes") }
        // Room for the new file while the old one is still there: it will not be bigger than the old one, nor smaller than a third of it.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           Int(free) < before / 2 + 300_000_000 {
            throw StudioRender.error("there is not enough room on the iPad to make the smaller copy (it needs about \(before / 2 / 1_000_000 + 300) MB free)")
        }
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("shrink-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: made) }
        let length = try await encode(movie, to: made, cancel: cancel, progress: progress)

        let after = size(of: made)
        // Whole, or not at all: it must play, be as long as the recording, and keep its sound if it had some.
        let was = AVURLAsset(url: movie), now = AVURLAsset(url: made)
        let playable = try await now.load(.isPlayable)
        let duration = try await now.load(.duration).seconds
        let soundsBefore = try await was.loadTracks(withMediaType: .audio).count
        let soundsNow = try await now.loadTracks(withMediaType: .audio).count
        guard playable, abs(duration - length) < 1, soundsBefore == soundsNow else { throw StudioRender.error("the smaller copy did not come out whole, so the recording was left as it was") }
        guard Double(after) <= Double(before) * worthwhile else {
            return Outcome(before: before, after: before, shrunk: false, why: "it would only have saved \(max(0, 100 - after * 100 / max(1, before)))%, so it was left as it was")
        }
        guard FileManager.default.fileExists(atPath: movie.path) else { throw StudioRender.error("the recording was deleted meanwhile") }
        _ = try FileManager.default.replaceItemAt(movie, withItemAt: made)
        return Outcome(before: before, after: after, shrunk: true, why: nil)
    }

    static func size(of url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    /// `movie` as HEVC at `url`. Returns how long the picture is, in seconds.
    static func encode(_ movie: URL, to url: URL, cancel: StudioCancel, progress: @escaping (Double) -> Void) async throws -> Double {
        let asset = AVURLAsset(url: movie)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw StudioRender.error("there is no picture in this recording") }
        let size = try await video.load(.naturalSize), turn = try await video.load(.preferredTransform)
        let range = try await video.load(.timeRange), nominal = try await video.load(.nominalFrameRate), rate = try await video.load(.estimatedDataRate)
        let descriptions = try await video.load(.formatDescriptions)
        let fps = nominal > 0 ? Double(nominal) : 60
        let length = max(0.1, range.duration.seconds)

        let reader = try AVAssetReader(asset: asset)
        let pictures = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        pictures.alwaysCopiesSampleData = false
        guard reader.canAdd(pictures) else { throw StudioRender.error("the recording could not be read back") }
        reader.add(pictures)
        var sounds: AVAssetReaderTrackOutput?
        var soundHint: CMFormatDescription?
        if let heard = try await asset.loadTracks(withMediaType: .audio).first {
            let output = AVAssetReaderTrackOutput(track: heard, outputSettings: nil) // the sound as it is: not decoded, not encoded again
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                sounds = output
                soundHint = try await heard.load(.formatDescriptions).first
            }
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate(was: Double(rate), width: Double(size.width), height: Double(size.height), fps: fps),
                AVVideoMaxKeyFrameIntervalDurationKey: 4,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
        ]
        // The colours as the recording says they are: left to the encoder, a screen in Display P3 could come out a little dull.
        if let description = descriptions.first, let tags = CMFormatDescriptionGetExtensions(description) as? [String: Any],
           let primaries = tags[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
           let transfer = tags[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
           let matrix = tags[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
            var tagged = settings
            tagged[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix]
            if writer.canApply(outputSettings: tagged, forMediaType: .video) { settings = tagged }
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw StudioRender.error("this iPad cannot make HEVC video") }
        let pictureIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        pictureIn.expectsMediaDataInRealTime = false
        pictureIn.transform = turn
        guard writer.canAdd(pictureIn) else { throw StudioRender.error("this iPad cannot make a video of this kind") }
        writer.add(pictureIn)
        var soundIn: AVAssetWriterInput?
        if sounds != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: soundHint)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); soundIn = input } else { sounds = nil }
        }

        guard writer.startWriting() else { throw writer.error ?? StudioRender.error("the smaller copy could not be started") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? StudioRender.error("the recording could not be read") }

        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.engikode.enginote.shrink")
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
                            fail(writer.error ?? StudioRender.error("the smaller copy could not be written"))
                            finished = true
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        seen(sample)
                    }
                }
            }
            pump(pictureIn, pictures) { sample in progress(min(1, max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds / length))) }
            if let input = soundIn, let output = sounds { pump(input, output) { _ in } }

            group.notify(queue: queue) {
                if reader.status == .failed { fail(reader.error ?? StudioRender.error("the recording could not be read")) }
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
                        done.resume(throwing: writer.error ?? StudioRender.error("the smaller copy could not be finished"))
                    }
                }
            }
        }
        progress(1)
        return length
    }
}
