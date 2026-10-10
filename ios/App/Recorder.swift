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

    /// A recording has been started and not yet stopped.
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writer != nil
    }

    /// Start recording. `done` is called on the main thread with nil, or with what went wrong
    /// (which includes the user saying no to the system's question).
    func start(quality name: String, microphone: Bool, done: @escaping (String?) -> Void) {
        let screen = RPScreenRecorder.shared()
        guard screen.isAvailable, !screen.isRecording, !isActive else {
            done("Screen recording is not available right now.")
            return
        }
        let url: URL
        let writer: AVAssetWriter
        do {
            let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
            url = folder.appendingPathComponent("EngiNote \(stamp.string(from: Date())).mov")
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            done(error.localizedDescription)
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
        if let known = Recorder.qualities[name] { self.quality = known }
        lock.unlock()

        screen.isMicrophoneEnabled = microphone
        screen.startCapture(handler: { [weak self] buffer, type, error in
            if error == nil { self?.take(buffer, type) }
        }, completionHandler: { [weak self] error in
            if error != nil { self?.forget() }
            DispatchQueue.main.async { done(error?.localizedDescription) }
        })
    }

    /// Stop and finish the movie. `done` is called on the main thread with the file (nil if there
    /// is nothing to keep) and with what went wrong, if anything did.
    func stop(done: @escaping (URL?, String?) -> Void) {
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
        guard let writer = writer, failure == nil else { return }

        switch type {
        case .video:
            // The movie is set up on its first frame, because only a frame says how the screen is turned.
            if video == nil { begin(writer, with: buffer) }
            if writer.status == .writing, let video = video, video.isReadyForMoreMediaData, !video.append(buffer) {
                fail(writer.error?.localizedDescription ?? "The picture could not be written.")
            }
        case .audioMic:
            if writer.status == .writing, let audio = audio, audio.isReadyForMoreMediaData, !audio.append(buffer) {
                fail(writer.error?.localizedDescription ?? "The sound could not be written.")
            }
        default:
            break // the app makes no sound of its own
        }
        if writer.status == .failed { fail(writer.error?.localizedDescription ?? "The recording stopped.") }
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
