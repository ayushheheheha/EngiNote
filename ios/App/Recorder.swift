import AVFoundation
import ImageIO
import ReplayKit
import UIKit

/// Records the app's own screen, with the microphone, as a movie in the app's Documents folder
/// (which the Files app shows under "On My iPad > EngiNote").
///
/// Only the 16:9 band across the middle of the screen is kept. That band is exactly where the page
/// puts its 16:9 window (full width, centred), so nothing has to be measured or cropped frame by
/// frame: the encoder is asked for a 16:9 picture and told to fill it, which trims the rest away.
/// The page's recording controls sit below that band and so are never in the picture.
///
/// Made for long recordings: the movie is written in 10-second pieces, so if the app is killed or
/// the battery runs out, what was recorded up to then is still a playable file.
///
/// None of this can be run off the device: it was written against the documentation and is only
/// proven by recording on the iPad.
final class Recorder {
    struct Quality {
        let width: Int
        let height: Int
        let bitRate: Int // bits a second, on average
    }

    /// The choices offered by the page (index.html, #rec-quality): the names must match.
    static let qualities: [String: Quality] = [
        "high": Quality(width: 1920, height: 1080, bitRate: 8_000_000),
        "standard": Quality(width: 1920, height: 1080, bitRate: 4_000_000),
        "small": Quality(width: 1280, height: 720, bitRate: 2_000_000),
    ]

    /// Called on the main thread, once, if writing fails while recording.
    var onFailure: ((String) -> Void)?

    // Frames arrive on ReplayKit's own thread; everything below is touched only with the lock held.
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var quality = Quality(width: 1920, height: 1080, bitRate: 4_000_000)
    private var microphone = true
    private var failure: String?
    private var file: URL?
    // Pausing. ReplayKit cannot pause, so while paused its frames are simply not written; and from
    // then on every piece is written `offset` earlier than it was made, so the movie has no hole
    // where the pause was. `lastEnd` is where the movie has got to, in its own time.
    private var paused = false
    private var rejoin = false // resumed: the next frame decides the new `offset`
    private var offset = CMTime.zero
    private var lastEnd = CMTime.zero
    private var soundPieces = 0 // pieces of sound written so far

    // The voice. The app listens to the microphone itself and writes what it hears into the movie;
    // ReplayKit records the picture only. (ReplayKit can pass on the microphone too, but on the
    // iPad this was made for it passed on nothing: recordings came out silent. So that is only the
    // last resort, if the app's own listening cannot start.)
    // "Enhanced" listens through the system's voice processing, the kind calls use, which takes
    // the background noise out; it is also what makes iPadOS offer its stronger "Voice Isolation"
    // microphone mode in Control Centre.
    // Main thread only:
    private let engine = AVAudioEngine()
    private var listening = false
    /// How much later (+) or earlier (-) the voice is written than it was heard: the knob
    /// to turn if voice and picture turn out not to line up on the real device.
    private static let voiceShift = CMTime(value: 0, timescale: 1000) // ms

    /// A recording has been started and not yet stopped.
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writer != nil
    }

    /// The movie being written right now, if any: not to be played, shared or deleted yet.
    var activeFile: URL? {
        lock.lock()
        defer { lock.unlock() }
        return writer == nil ? nil : file
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    /// Sound has actually reached the movie. (False a few seconds in means the voice is being lost.)
    var hasSound: Bool {
        lock.lock()
        defer { lock.unlock() }
        return soundPieces > 0
    }

    /// Where recordings are kept: the app's Documents folder.
    static func folder() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    /// Start recording. `enhance`: record the voice with the background noise taken out.
    /// `done` is called on the main thread: with what went wrong (which includes the user saying
    /// no to the system's question), or nil; and with something the user should know even though
    /// recording did start (the app could not listen to the microphone itself).
    func start(quality name: String, microphone: Bool, enhance: Bool, done: @escaping (_ error: String?, _ note: String?) -> Void) {
        let screen = RPScreenRecorder.shared()
        guard screen.isAvailable, !screen.isRecording, !isActive else {
            done("Screen recording is not available right now.", nil)
            return
        }
        guard microphone else {
            capture(quality: name, microphone: false, ownVoice: false, note: nil, done: done)
            return
        }
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var note: String?
                var own = false
                if allowed {
                    do {
                        try self.listen(enhanced: enhance)
                        own = true
                    } catch {
                        self.stopListening()
                        note = "The microphone could not be started the usual way (\(error.localizedDescription)). Check that the recording has sound."
                    }
                } else {
                    note = "EngiNote is not allowed to use the microphone (Settings > EngiNote): check that the recording has sound."
                }
                self.capture(quality: name, microphone: microphone, ownVoice: own, note: note, done: done)
            }
        }
    }

    // The recording itself. `ownVoice`: the app is already listening to the microphone, so ReplayKit must not.
    private func capture(quality name: String, microphone: Bool, ownVoice: Bool, note: String?, done: @escaping (String?, String?) -> Void) {
        let screen = RPScreenRecorder.shared()
        let url: URL
        let writer: AVAssetWriter
        do {
            let folder = try Recorder.folder()
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
            url = folder.appendingPathComponent("EngiNote \(stamp.string(from: Date())).mov")
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            stopListening()
            done(error.localizedDescription, nil)
            return
        }
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        lock.lock()
        self.writer = writer
        self.video = nil
        self.audio = nil
        self.failure = nil
        self.file = url
        self.microphone = microphone
        self.paused = false
        self.rejoin = false
        self.offset = .zero
        self.lastEnd = .zero
        self.soundPieces = 0
        if let known = Recorder.qualities[name] { self.quality = known }
        lock.unlock()

        screen.isMicrophoneEnabled = microphone && !ownVoice
        screen.startCapture(handler: { [weak self] buffer, type, error in
            if error == nil { self?.take(buffer, type) }
        }, completionHandler: { [weak self] error in
            if error != nil { self?.forget() }
            DispatchQueue.main.async {
                if error != nil { self?.stopListening() }
                done(error?.localizedDescription, error == nil ? note : nil)
            }
        })
    }

    // MARK: The voice

    /// Start listening to the microphone; `enhanced`: through the system's voice processing. What is
    /// heard goes to take(), like ReplayKit's own sound would; until a recording is running it is dropped there.
    private func listen(enhanced: Bool) throws {
        listening = true
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let microphone = engine.inputNode
        try microphone.setVoiceProcessingEnabled(enhanced)
        let format = microphone.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount == 1 || format.channelCount == 2 else {
            throw NSError(domain: "EngiNote", code: 1, userInfo: [NSLocalizedDescriptionKey: "the microphone's sound is in a form this app cannot record"])
        }
        microphone.removeTap(onBus: 0)
        microphone.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] heard, time in
            guard let self = self, let piece = Recorder.piece(from: heard, at: time) else { return }
            self.take(piece, .audioMic)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stop listening, if listening. Safe to call at any time.
    private func stopListening() {
        guard listening else { return }
        listening = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// What the microphone heard, as a piece of sound the movie can take, timed on the same clock
    /// as ReplayKit's picture (the device's own).
    private static func piece(from heard: AVAudioPCMBuffer, at time: AVAudioTime) -> CMSampleBuffer? {
        guard time.isHostTimeValid, heard.frameLength > 0 else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(heard.format.sampleRate)),
            presentationTimeStamp: CMTimeAdd(CMClockMakeHostTimeFromSystemUnits(time.hostTime), voiceShift),
            decodeTimeStamp: .invalid
        )
        var made: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: heard.format.formatDescription, sampleCount: CMItemCount(heard.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &made
        )
        guard status == noErr, let piece = made else { return nil }
        let filled = CMSampleBufferSetDataBufferFromAudioBufferList(
            piece, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: heard.audioBufferList
        )
        return filled == noErr ? piece : nil
    }

    /// Leave out everything from now until resume(). The movie carries on from there with no gap.
    func pause() {
        lock.lock()
        paused = true
        lock.unlock()
    }

    func resume() {
        lock.lock()
        if paused {
            paused = false
            rejoin = true
        }
        lock.unlock()
    }

    /// Stop and finish the movie. `done` is called on the main thread with the file (nil if there
    /// is nothing to keep) and with what went wrong, if anything did.
    func stop(done: @escaping (URL?, String?) -> Void) {
        stopListening()
        RPScreenRecorder.shared().stopCapture { [weak self] error in
            guard let self = self else { return }
            self.lock.lock()
            let writer = self.writer
            let video = self.video
            let audio = self.audio
            let file = self.file
            let failure = self.failure
            self.writer = nil
            self.lock.unlock()

            guard let writer = writer, video != nil, writer.status == .writing else {
                // Nothing was being written, or writing had failed. A failed movie's finished pieces
                // may still be on disk, and those are worth keeping.
                let kept = file.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                let reason = failure ?? error?.localizedDescription ?? "Nothing was recorded."
                DispatchQueue.main.async { done(kept, reason) }
                return
            }
            video?.markAsFinished()
            audio?.markAsFinished()
            writer.finishWriting {
                let problem = writer.status == .completed ? failure : (writer.error?.localizedDescription ?? "The recording could not be finished.")
                DispatchQueue.main.async { done(file, problem) }
            }
        }
    }

    private func forget() {
        lock.lock()
        writer = nil
        lock.unlock()
    }

    // With the lock held.
    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message
        let report = onFailure
        DispatchQueue.main.async { report?(message) }
    }

    /// One piece of picture or sound from ReplayKit.
    private func take(_ buffer: CMSampleBuffer, _ type: RPSampleBufferType) {
        guard CMSampleBufferDataIsReady(buffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let writer = writer, failure == nil, !paused else { return }
        guard type == .video || type == .audioMic else { return } // the app makes no sound of its own

        // Back from a pause: the movie goes on from where it had got to, starting with a frame of
        // picture. That frame's own time says how far to move everything from here on.
        if rejoin {
            guard type == .video else { return }
            if video != nil { offset = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(buffer), lastEnd) }
            rejoin = false
        }
        // The movie is set up on its first frame, because only a frame says how the screen is turned.
        if type == .video, video == nil { begin(writer, with: buffer) }

        if writer.status == .failed { fail(writer.error?.localizedDescription ?? "The recording stopped.") }
        guard writer.status == .writing, let input = (type == .video ? video : audio), input.isReadyForMoreMediaData else { return }
        guard let piece = CMTimeCompare(offset, .zero) == 0 ? buffer : moved(buffer, earlierBy: offset) else { return }
        guard input.append(piece) else {
            fail(writer.error?.localizedDescription ?? "The recording could not be written.")
            return
        }
        // A frame of picture often does not say how long it lasts: a sixtieth of a second will do.
        let length = CMSampleBufferGetDuration(piece)
        let lasts = length.isValid && CMTimeCompare(length, .zero) > 0 ? length : CMTime(value: 1, timescale: 60)
        let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(piece), lasts)
        if CMTimeCompare(end, lastEnd) > 0 { lastEnd = end }
        if type == .audioMic { soundPieces += 1 }
    }

    /// A copy of a piece of picture or sound, timed `offset` earlier.
    private func moved(_ buffer: CMSampleBuffer, earlierBy offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset) }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleTimingEntryCount: timing.count, sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy
    }

    // With the lock held: add picture and sound to the movie and start it at this frame's time.
    private func begin(_ writer: AVAssetWriter, with buffer: CMSampleBuffer) {
        // ReplayKit may hand over frames lying on their side, saying so in an attachment. Then the
        // 16:9 band runs down the frame instead of across it: the picture is encoded tall, and
        // marked to be turned upright when played.
        // ponytail: the turning directions follow the documentation and are untested; if a recording
        // plays on its side or upside down, this switch is the place.
        var turn = CGAffineTransform.identity
        var sideways = false
        if let number = CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value) {
            switch orientation {
            case .right, .rightMirrored:
                turn = CGAffineTransform(rotationAngle: .pi / 2)
                sideways = true
            case .left, .leftMirrored:
                turn = CGAffineTransform(rotationAngle: -.pi / 2)
                sideways = true
            case .down, .downMirrored:
                turn = CGAffineTransform(rotationAngle: .pi)
            default:
                break
            }
        }

        let size: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, // plays and edits everywhere, unlike HEVC on some PCs
            AVVideoWidthKey: sideways ? quality.height : quality.width,
            AVVideoHeightKey: sideways ? quality.width : quality.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill, // this is the crop to 16:9
        ]
        var picture = size
        picture[AVVideoCompressionPropertiesKey] = [
            AVVideoAverageBitRateKey: quality.bitRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoExpectedSourceFrameRateKey: 60,
        ] as [String: Any]
        // Settings the encoder will not take would stop the app, not just the recording: ask first.
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: writer.canApply(outputSettings: picture, forMediaType: .video) ? picture : size)
        video.expectsMediaDataInRealTime = true
        video.transform = turn
        guard writer.canAdd(video) else {
            fail("This iPad cannot record at this quality.")
            return
        }
        writer.add(video)
        self.video = video

        let sound: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        if microphone, writer.canApply(outputSettings: sound, forMediaType: .audio) {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: sound)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                self.audio = audio
            }
        }

        guard writer.startWriting() else {
            fail(writer.error?.localizedDescription ?? "The recording could not be started.")
            return
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
    }
}
