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
        // Fine handwriting is the hardest thing to encode: thin strokes smear at a low bit rate. Frames are
        // asked for at 60 a second (see begin()), which is what makes the pen's line move smoothly.
        "high": Quality(width: 1920, height: 1080, bitRate: 14_000_000),
        "standard": Quality(width: 1920, height: 1080, bitRate: 7_000_000),
        "small": Quality(width: 1280, height: 720, bitRate: 3_000_000),
    ]

    /// Called on the main thread, once, if writing fails while recording.
    var onFailure: ((String) -> Void)?
    /// The mic check. Called on the main thread about twenty times a second while the page is
    /// showing the sound: how loud each twentieth of a second was, from 0 (silence) to 1.
    var onLevels: (([Double]) -> Void)?
    /// Called on the main thread when a mic check that was asked for cannot go on, with the reason.
    var onCheckFailed: ((String) -> Void)?

    // Frames arrive on ReplayKit's own thread; everything below is touched only with the lock held.
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var quality = Quality(width: 1920, height: 1080, bitRate: 7_000_000)
    private var wholeScreen = false // keep all of the screen, not just the 16:9 band across its middle
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
    private var metering = false // the page is showing the sound: see `checking`
    private var heardAt: TimeInterval = 0 // when the microphone last handed over sound (the device's uptime)

    // What Studio needs to know about this recording afterwards (StudioCore.swift, Sidecar): where the pen
    // wrote, where the camera bubble was, and when. Times are the wall clock in ms, because the page's
    // clock is the wall clock; the first frame and the pauses are timed on it too, to line the two up.
    private var sidecar = Sidecar()
    private var pausedSince: Double?

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
    private var enhanced = false // how it is listening, or last was
    private var resumes = false // a mic check was cut short by the app leaving the screen: see leftScreen

    // The mic check: the page shows how loud the microphone's sound is, before a recording or
    // during one. It is the same listening, and there is only ever the one: a recording that
    // starts while a check is on joins it, and one that ends leaves it running for the check.
    // Nothing here may cost a recording its sound: unless the listening a check left behind is
    // plainly what the recording wants, and alive, the recording starts its own, as it always did.
    /// The page wants the levels. (Read where the sound arrives too, hence the lock.)
    private var checking: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return metering
        }
        set {
            lock.lock()
            metering = newValue
            lock.unlock()
        }
    }
    // The level being worked out. Touched only where the sound arrives.
    private var squares: Float = 0
    private var counted = 0
    /// What the page draws as silence and as full height, in decibels below the loudest sound the
    /// microphone can report: the knobs to turn if the bars sit too low or too high on the real device.
    private static let quietest: Float = -55
    private static let loudest: Float = -5
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

    /// A note's name as the start of a file name: no characters a file name cannot hold, not too long, never empty.
    static func fileSafe(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(CharacterSet.controlCharacters)
        let ends = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        let clean = title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: ends)
        return clean.isEmpty ? "EngiNote" : String(clean.prefix(60))
    }

    /// Start recording. `wide`: the page's 16:9 window is on, and the video is to be that window;
    /// otherwise it is the whole screen. `enhance`: record the voice with the background noise taken out.
    /// `done` is called on the main thread: with what went wrong (which includes the user saying
    /// no to the system's question), or nil; and with something the user should know even though
    /// recording did start (the app could not listen to the microphone itself).
    func start(quality name: String, wide: Bool, microphone: Bool, enhance: Bool, title: String, done: @escaping (_ error: String?, _ note: String?) -> Void) {
        lock.lock()
        wholeScreen = !wide
        lock.unlock()
        let screen = RPScreenRecorder.shared()
        guard screen.isAvailable, !screen.isRecording, !isActive else {
            done("Screen recording is not available right now.", nil)
            return
        }
        guard microphone else {
            capture(quality: name, microphone: false, ownVoice: false, note: nil, title: title, done: done)
            return
        }
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var note: String?
                var own = false
                if allowed, self.hears(enhanced: enhance) {
                    own = true // a mic check is listening already, this very way: the recording joins it
                } else if allowed {
                    do {
                        self.stopListening() // a mic check listening some other way, or one gone quiet
                        try self.listen(enhanced: enhance)
                        own = true
                    } catch {
                        self.stopListening()
                        note = "The microphone could not be started the usual way (\(error.localizedDescription)). Check that the recording has sound."
                    }
                } else {
                    note = "EngiNote is not allowed to use the microphone (Settings > EngiNote): check that the recording has sound."
                }
                self.capture(quality: name, microphone: microphone, ownVoice: own, note: note, title: title, done: done)
            }
        }
    }

    // The recording itself. `ownVoice`: the app is already listening to the microphone, so ReplayKit must not.
    private func capture(quality name: String, microphone: Bool, ownVoice: Bool, note: String?, title: String, done: @escaping (String?, String?) -> Void) {
        let screen = RPScreenRecorder.shared()
        let url: URL
        let writer: AVAssetWriter
        do {
            let folder = try Recorder.folder()
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
            url = folder.appendingPathComponent("\(Recorder.fileSafe(title)) \(stamp.string(from: Date())).mov")
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            stopListening(unlessChecking: true)
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
        self.sidecar = Sidecar()
        self.pausedSince = nil
        if let known = Recorder.qualities[name] { self.quality = known }
        lock.unlock()

        screen.isMicrophoneEnabled = microphone && !ownVoice
        screen.startCapture(handler: { [weak self] buffer, type, error in
            if error == nil { self?.take(buffer, type) }
        }, completionHandler: { [weak self] error in
            if error != nil { self?.forget() }
            DispatchQueue.main.async {
                if error != nil { self?.stopListening(unlessChecking: true) }
                done(error?.localizedDescription, error == nil ? note : nil)
            }
        })
    }

    // MARK: The voice

    /// Start listening to the microphone; `enhanced`: through the system's voice processing. What is
    /// heard goes to take(), like ReplayKit's own sound would; until a recording is running it is dropped there.
    private func listen(enhanced: Bool) throws {
        listening = true
        self.enhanced = enhanced
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
            guard let self = self else { return }
            if let piece = Recorder.piece(from: heard, at: time) { self.take(piece, .audioMic) }
            self.measure(heard) // for the mic check; after the recording has had its sound
        }
        engine.prepare()
        try engine.start()
    }

    /// Stop listening, if listening. Safe to call at any time. `unlessChecking`: a recording is
    /// done with the microphone, but a mic check on the page may still be using it.
    private func stopListening(unlessChecking: Bool = false) {
        guard listening, !(unlessChecking && checking) else { return }
        listening = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: The mic check

    /// Show the page how loud the microphone's sound is (onLevels), or stop. `enhance`: listen
    /// through the voice processing, as a recording with Enhance would. During a recording the
    /// sound is the recording's own, whatever `enhance` says.
    func check(on: Bool, enhance: Bool) {
        checking = on
        guard on else {
            if !isActive { stopListening() } // a recording still needs it
            return
        }
        guard !isActive else { return } // a recording is listening already
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                // Switched off again meanwhile, or a recording has begun: then there is nothing to start.
                guard let self = self, self.checking, !self.isActive else { return }
                guard allowed else {
                    self.failCheck("EngiNote is not allowed to use the microphone (Settings > EngiNote).")
                    return
                }
                if self.listening, self.enhanced == enhance, self.engine.isRunning { return } // as asked, already
                do {
                    self.stopListening() // Enhance was switched: listen the other way
                    try self.listen(enhanced: enhance)
                } catch {
                    self.stopListening()
                    self.failCheck("The microphone could not be started (\(error.localizedDescription)).")
                }
            }
        }
    }

    private func failCheck(_ reason: String) {
        checking = false
        onCheckFailed?(reason)
    }

    /// The app has left the screen, where iPadOS does not let it listen (`away`), or is back: a
    /// mic check lets go of the microphone, and takes it up again.
    func leftScreen(_ away: Bool) {
        if away {
            resumes = listening && checking
            stopListening()
            return
        }
        let again = resumes
        resumes = false
        guard again, checking, !listening, !isActive else { return }
        do {
            try listen(enhanced: enhanced)
        } catch {
            stopListening()
            failCheck("The mic check could not go on (\(error.localizedDescription)).")
        }
    }

    /// The app is listening already, the way a recording now wants, and sound really is arriving.
    private func hears(enhanced: Bool) -> Bool {
        lock.lock()
        let last = heardAt
        lock.unlock()
        return listening && self.enhanced == enhanced && engine.isRunning && ProcessInfo.processInfo.systemUptime - last < 0.5
    }

    /// Where the sound arrives: note that it did and, for a mic check, work out how loud each
    /// twentieth of a second of it was and hand that to the main thread.
    private func measure(_ heard: AVAudioPCMBuffer) {
        lock.lock()
        heardAt = ProcessInfo.processInfo.systemUptime
        let wanted = metering
        lock.unlock()
        guard wanted, heard.frameLength > 0, let samples = heard.floatChannelData?[0] else { return }
        let window = max(1, Int(heard.format.sampleRate / 20))
        var levels: [Double] = []
        for i in 0..<Int(heard.frameLength) {
            squares += samples[i] * samples[i]
            counted += 1
            guard counted >= window else { continue }
            // Loudness as the ear has it (decibels), from `quietest` to `loudest`, as 0 to 1.
            let decibels = 10 * log10(max(squares / Float(counted), 1e-12))
            let level = (decibels - Recorder.quietest) / (Recorder.loudest - Recorder.quietest)
            levels.append(level.isFinite ? Double(min(max(level, 0), 1)) : 0)
            squares = 0
            counted = 0
        }
        guard !levels.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onLevels?(levels) }
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
        if !paused { pausedSince = Sidecar.now() }
        paused = true
        lock.unlock()
    }

    func resume() {
        lock.lock()
        if paused {
            paused = false
            rejoin = true
            if let since = pausedSince { sidecar.pauses.append([since, Sidecar.now()]) }
            pausedSince = nil
        }
        lock.unlock()
    }

    /// The pen's path from the page (app.js, sendTrace), and the part of the screen the video shows.
    func addTrace(points: [[Double]], window: [Double]?) {
        lock.lock()
        sidecar.pen.append(contentsOf: points.filter { $0.count == 4 && $0.allSatisfy(\.isFinite) })
        if let window = window, window.count == 4, window.allSatisfy(\.isFinite) { sidecar.window = window }
        lock.unlock()
    }

    /// Where the camera bubble is now (screen points) and how round its corners are: called about once
    /// a second while recording, and only a change is kept.
    func addBubble(_ frame: CGRect, radius: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard writer != nil, sidecar.startedAt > 0 else { return }
        let entry = [Sidecar.now(), Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height), radius]
        if let last = sidecar.bubble.last, last[1...] == entry[1...] { return }
        sidecar.bubble.append(entry)
    }

    /// The camera bubble was switched off: from now on there is none in the picture.
    func bubbleGone() {
        lock.lock()
        defer { lock.unlock() }
        guard writer != nil, sidecar.startedAt > 0, let last = sidecar.bubble.last, last[3] > 0 else { return }
        sidecar.bubble.append([Sidecar.now(), 0, 0, 0, 0, 0])
    }

    /// Write what Studio needs beside the movie. Not being able to is no reason to lose the recording.
    private func saveSidecar(for movie: URL?) {
        lock.lock()
        let data = sidecar
        lock.unlock()
        guard let movie = movie, data.startedAt > 0 else { return }
        data.save(for: movie)
    }

    /// Stop and finish the movie. `done` is called on the main thread with the file (nil if there
    /// is nothing to keep) and with what went wrong, if anything did.
    func stop(done: @escaping (URL?, String?) -> Void) {
        stopListening(unlessChecking: true)
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
            // A mic check switched off while the movie was being closed left the listening on: end
            // it now. (Never the listening of a new recording: that one would be active by now.)
            DispatchQueue.main.async {
                if !self.isActive { self.stopListening(unlessChecking: true) }
            }

            self.saveSidecar(for: file)
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

        // The picture's size, as it is watched. For the 16:9 window: the quality's own. For the whole
        // screen: the screen's shape, with its shorter side the quality's height (1080 or 720).
        var across = quality.width
        var down = quality.height
        if wholeScreen, let image = CMSampleBufferGetImageBuffer(buffer) {
            let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
            let screenAcross = sideways ? height : width, screenDown = sideways ? width : height
            let even = { (n: Int) in max(2, n / 2 * 2) } // encoders want even numbers
            if screenAcross >= screenDown, screenDown > 0 {
                across = even(quality.height * screenAcross / screenDown)
                down = quality.height
            } else if screenAcross > 0 {
                across = quality.height
                down = even(quality.height * screenDown / screenAcross)
            }
        }
        let size: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, // plays and edits everywhere, unlike HEVC on some PCs
            AVVideoWidthKey: sideways ? down : across,
            AVVideoHeightKey: sideways ? across : down,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill, // for the 16:9 window, this is the crop
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
        sidecar.startedAt = Sidecar.now()
    }
}
