import AVFoundation
import ImageIO
import ReplayKit

/// The broadcast extension: iPadOS runs it while the whole iPad is recorded and hands it every frame of the screen,
/// the sound apps play, and (if switched on in Control Center) ReplayKit's own microphone. It writes them to
/// <id>.screen.mov in the shared folder; the app writes the voice beside it and joins the two at the end (Joiner.swift).
///
/// Written in 10-second pieces like the EngiNote recorder's movie, so a crash keeps what was recorded. An extension
/// may use only about 50 MB of memory: nothing here keeps frames, and the sound waiting its turn is capped.
///
/// Unverified off the device: written against the documentation, proven only by recording on the iPad.
final class SampleHandler: RPBroadcastSampleHandler {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var sound: [RPSampleBufferType: AVAssetWriterInput] = [:]
    private var held: [RPSampleBufferType: [CMSampleBuffer]] = [:] // sound the movie was not ready for yet
    private var ends: [RPSampleBufferType: Double] = [:]           // where each track has got to (movie time, host seconds)
    private var id = ""
    private var quality = Shared.qualities["standard"]!
    private var wide = false     // keep only the 16:9 band across the middle, as the EngiNote recorder's lecture mode
    private var appSound = true  // record the sound apps play
    private var ownMic = false   // the app is not writing the voice: take ReplayKit's microphone
    private var pauses = Pauses()
    private var finished = false
    private static let mostHeld = 200

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let d = Shared.defaults
        guard let folder = Shared.folder else {
            return quit("The recorder's shared folder is missing. Install EngiNote Recorder again with the updater.")
        }
        id = Shared.newID()
        do {
            let w = try AVAssetWriter(outputURL: folder.appendingPathComponent("\(id).screen.mov"), fileType: .mov)
            w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            lock.lock()
            writer = w
            quality = Shared.qualities[d?.string(forKey: "quality") ?? ""] ?? quality
            wide = d?.bool(forKey: "wide") ?? false
            appSound = d?.object(forKey: "appSound") as? Bool ?? true
            ownMic = !Shared.voiceAlive
            pauses = Pauses()
            lock.unlock()
        } catch {
            return quit("The recording could not be started: \(error.localizedDescription)")
        }
        Pauses().save(d)
        d?.set(id, forKey: "live")
        Shared.observe("pause") { [weak self] in
            guard let self else { return }
            let p = Pauses.load(Shared.defaults)
            self.lock.lock()
            self.pauses = p
            self.lock.unlock()
        }
        Shared.observe("stop") { [weak self] in
            self?.finish()
            self?.quit("Saved. The recording is in EngiNote Recorder.")
        }
        Shared.post("started")
    }

    override func broadcastFinished() { finish() }

    /// End the broadcast, with what iPadOS should say. Later, on the main thread: it may be called with the lock held,
    /// and ending calls broadcastFinished, which takes the lock.
    private func quit(_ why: String) {
        DispatchQueue.main.async {
            self.finishBroadcastWithError(NSError(domain: "EngiNoteRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: why]))
        }
    }

    /// Close the movie (waits for it: the extension may be ended as soon as this returns), and tell the app.
    private func finish() {
        lock.lock()
        guard !finished, let w = writer else { return lock.unlock() }
        finished = true
        for (type, input) in sound { drain(type, input, w) }
        let started = w.status == .writing
        if started {
            video?.markAsFinished()
            sound.values.forEach { $0.markAsFinished() }
        }
        lock.unlock()
        if started {
            let wait = DispatchSemaphore(value: 0)
            w.finishWriting { wait.signal() }
            _ = wait.wait(timeout: .now() + 20)
        }
        var part = Part.load(id, "screen") ?? Part()
        part.done = w.status == .completed
        part.save(id, "screen")
        Shared.defaults?.removeObject(forKey: "live")
        Shared.post("ended")
    }

    override func processSampleBuffer(_ buffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard CMSampleBufferDataIsReady(buffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let w = writer, !finished, w.status != .failed else { return }
        switch type {
        case .video: break
        case .audioApp: guard appSound else { return }
        case .audioMic: guard ownMic else { return }
        @unknown default: return
        }
        let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        guard let shift = pauses.shift(t), let piece = buffer.moved(earlierBy: shift) else { return }
        // The movie is set up on its first frame, because only a frame says how the screen is turned.
        if type == .video, video == nil { begin(w, with: piece) }
        guard w.status == .writing else { return }
        // A pause reaches this process a moment after it began: a piece made in that moment is already written,
        // and anything placed before it would make the movie run backwards. Leave such pieces out.
        guard t - shift >= (ends[type] ?? -.infinity) - 0.001 else { return }
        ends[type] = piece.end
        if type == .video {
            if video?.isReadyForMoreMediaData == true { _ = video?.append(piece) } // a frame left out: the one before stays up a moment
            return
        }
        // Sound cannot be left out (a hole in it is heard), so it waits its turn.
        guard let input = sound[type] else { return }
        held[type, default: []].append(piece)
        if held[type]!.count > Self.mostHeld { held[type]!.removeFirst() }
        drain(type, input, w)
    }

    // With the lock held.
    private func drain(_ type: RPSampleBufferType, _ input: AVAssetWriterInput, _ w: AVAssetWriter) {
        while w.status == .writing, input.isReadyForMoreMediaData, let piece = held[type]?.first {
            held[type]!.removeFirst()
            _ = input.append(piece)
        }
    }

    // With the lock held: the picture's size and turn, as the EngiNote recorder works them out (Recorder.swift, begin).
    private func begin(_ w: AVAssetWriter, with buffer: CMSampleBuffer) {
        var turn = CGAffineTransform.identity
        var sideways = false
        if let number = CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value) {
            switch orientation {
            case .right, .rightMirrored: turn = CGAffineTransform(rotationAngle: .pi / 2); sideways = true
            case .left, .leftMirrored: turn = CGAffineTransform(rotationAngle: -.pi / 2); sideways = true
            case .down, .downMirrored: turn = CGAffineTransform(rotationAngle: .pi)
            default: break
            }
        }
        var across = quality.width, down = quality.height
        if !wide, let image = CMSampleBufferGetImageBuffer(buffer) {
            let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
            let screenAcross = sideways ? height : width, screenDown = sideways ? width : height
            let even = { (n: Int) in max(2, n / 2 * 2) }
            if screenAcross >= screenDown, screenDown > 0 {
                across = even(quality.height * screenAcross / screenDown)
            } else if screenAcross > 0 {
                across = quality.height
                down = even(quality.height * screenDown / screenAcross)
            }
        }
        let size: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: sideways ? down : across,
            AVVideoHeightKey: sideways ? across : down,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill, // with 16:9 on, this is the crop
        ]
        var picture = size
        picture[AVVideoCompressionPropertiesKey] = [
            AVVideoAverageBitRateKey: quality.bitRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoExpectedSourceFrameRateKey: 60,
        ] as [String: Any]
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: w.canApply(outputSettings: picture, forMediaType: .video) ? picture : size)
        v.expectsMediaDataInRealTime = true
        v.transform = turn
        guard w.canAdd(v) else { return quit("This iPad cannot record at this quality: choose a smaller one.") }
        w.add(v)
        video = v

        // The sound apps play is stereo; ReplayKit's microphone is a voice.
        let tracks: [(RPSampleBufferType, Bool, Int, Int)] = [(.audioApp, appSound, 2, 128_000), (.audioMic, ownMic, 1, 96_000)]
        for (type, wanted, channels, rate) in tracks where wanted {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: rate]
            guard w.canApply(outputSettings: settings, forMediaType: .audio) else { continue }
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) {
                w.add(a)
                sound[type] = a
            }
        }

        guard w.startWriting() else { return quit("The recording could not be started: \(w.error?.localizedDescription ?? "unknown")") }
        let start = CMSampleBufferGetPresentationTimeStamp(buffer)
        w.startSession(atSourceTime: start)
        Part(start: start.seconds).save(id, "screen")
    }
}
