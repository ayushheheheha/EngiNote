import AVFoundation
import UIKit

/// The app's half of a recording: it listens to the microphone itself (as the EngiNote recorder does, because
/// ReplayKit's microphone gave silent recordings on this iPad) and writes the voice to <id>.voice.mov in the shared
/// folder, on the device's clock, leaving out the pauses exactly as the extension does with the picture.
///
/// The listening also keeps the app running while other apps are in front (UIBackgroundModes: audio), which is what
/// lets the camera bubble, the pause button and the join at the end work. With the microphone off it plays silence
/// for the same reason.
///
/// Named Recorder, with folder() and activeFile, because the shared recordings list and Studio (native/App/Recordings.swift,
/// ios/App/Studio.swift) know the EngiNote recorder by those names.
final class Recorder {
    /// Where finished recordings are kept: the app's Documents (Files: On My iPad > EngiNote Recorder).
    static func folder() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    /// The movie being joined right now: not to be listed, played or edited yet. Main thread.
    var activeFile: URL?

    /// The mic check: how loud each twentieth of a second was (0 to 1), on the main thread.
    var onLevels: (([Double]) -> Void)?

    // Main thread only:
    private let engine = AVAudioEngine()
    private(set) var listening = false
    private var withMic = false, enhanced = false

    // Touched where the sound arrives, so only with the lock held:
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var pauses = Pauses()
    private var start: Double?
    private var end = -Double.infinity
    private var held: [CMSampleBuffer] = []
    private var clock = SoundClock()
    private var metering = false
    private var squares: Float = 0, counted = 0
    private(set) var pieces = 0

    /// How much later (+) or earlier (-) the voice is written than it was heard, in seconds: the knob if voice and
    /// picture turn out not to line up on the device.
    private static let voiceShift = 0.0

    init() {
        let center = NotificationCenter.default
        // A call, Siri or another app taking the microphone stops the engine; take it up again when they are done.
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.listening,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            try? self.engine.start()
        }
        // Headphones plugged in or out: the engine stops and its formats may change, so listen again from scratch.
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.listening else { return }
            let (mic, enh) = (self.withMic, self.enhanced)
            self.stopListening()
            try? self.listen(mic: mic, enhanced: enh)
        }
    }

    /// Start listening (`mic`), or playing silence. `enhanced`: through the system's voice processing, which takes the
    /// background noise out. Mixes with other apps, so a video playing in one is neither stopped nor stops this.
    func listen(mic: Bool, enhanced: Bool) throws {
        if listening, withMic == mic, self.enhanced == enhanced, engine.isRunning { return }
        stopListening()
        listening = true
        withMic = mic
        self.enhanced = enhanced
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(mic ? .playAndRecord : .playback, mode: .default, options: mic ? [.mixWithOthers, .defaultToSpeaker] : [.mixWithOthers])
        try session.setActive(true)
        _ = engine.mainMixerNode // the engine needs something to play: silence
        engine.mainMixerNode.outputVolume = 0
        if mic {
            let microphone = engine.inputNode
            try microphone.setVoiceProcessingEnabled(enhanced)
            if enhanced {
                // Voice processing turns other apps' sound down while it runs: not here, where that sound is being recorded.
                microphone.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            }
            let format = microphone.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount == 1 || format.channelCount == 2 else {
                throw NSError(domain: "EngiNoteRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "the microphone's sound is in a form this app cannot record"])
            }
            microphone.removeTap(onBus: 0)
            microphone.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] heard, time in
                guard let self else { return }
                if let piece = self.piece(from: heard, at: time) { self.take(piece) }
                self.measure(heard)
            }
        }
        engine.prepare()
        try engine.start()
    }

    /// Listening to the microphone (not just playing silence).
    var hearing: Bool { listening && withMic }

    func stopListening() {
        guard listening else { return }
        listening = false
        if withMic {
            engine.inputNode.removeTap(onBus: 0)
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var checking: Bool {
        get { lock.lock(); defer { lock.unlock() }; return metering }
        set { lock.lock(); metering = newValue; lock.unlock() }
    }

    // MARK: writing the voice

    /// Start writing what is heard into recording `id`'s voice file.
    func open(_ id: String) throws {
        guard let folder = Shared.folder else { throw NSError(domain: "EngiNoteRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "the shared folder is missing"]) }
        let w = try AVAssetWriter(outputURL: folder.appendingPathComponent("\(id).voice.mov"), fileType: .mov)
        w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
        a.expectsMediaDataInRealTime = true
        guard w.canAdd(a) else { throw NSError(domain: "EngiNoteRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "the voice cannot be written"]) }
        w.add(a)
        guard w.startWriting() else { throw w.error ?? NSError(domain: "EngiNoteRecorder", code: 4) }
        lock.lock()
        writer = w
        input = a
        pauses = Pauses()
        start = nil
        end = -.infinity
        held = []
        pieces = 0
        clock = SoundClock()
        lock.unlock()
    }

    func setPauses(_ p: Pauses) {
        lock.lock()
        pauses = p
        lock.unlock()
    }

    /// Finish the voice file; returns where it starts and whether it closed properly (nil when nothing was being written).
    func close() async -> Part? {
        lock.lock()
        let w = writer, a = input, start = self.start
        drain()
        writer = nil
        input = nil
        held = []
        lock.unlock()
        guard let w else { return nil }
        var part = Part(start: start)
        if w.status == .writing {
            a?.markAsFinished()
            await w.finishWriting()
        }
        part.done = w.status == .completed
        return part
    }

    var heardSomething: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pieces > 0
    }

    private func take(_ piece: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let w = writer, w.status == .writing else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(piece).seconds
        guard let shift = pauses.shift(t), let moved = piece.moved(earlierBy: shift), t - shift >= end - 0.001 else { return }
        if start == nil {
            start = t - shift
            w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(moved))
        }
        end = moved.end
        held.append(moved)
        if held.count > 200 { held.removeFirst() }
        drain()
    }

    // With the lock held.
    private func drain() {
        guard let w = writer, w.status == .writing, let a = input else { return }
        while a.isReadyForMoreMediaData, let piece = held.first {
            held.removeFirst()
            if a.append(piece) { pieces += 1 }
        }
    }

    // MARK: from the microphone's buffers (as the EngiNote recorder makes them: Recorder.swift, piece and measure)

    private func piece(from heard: AVAudioPCMBuffer, at time: AVAudioTime) -> CMSampleBuffer? {
        guard time.isHostTimeValid, heard.frameLength > 0 else { return nil }
        lock.lock()
        let host = CMTimeAdd(CMClockMakeHostTimeFromSystemUnits(time.hostTime), CMTime(seconds: Recorder.voiceShift, preferredTimescale: 1000))
        let start = clock.place(host: host, frames: Int(heard.frameLength), rate: heard.format.sampleRate)
        lock.unlock()
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(heard.format.sampleRate)), presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var made: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: heard.format.formatDescription, sampleCount: CMItemCount(heard.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &made
        )
        guard status == noErr, let piece = made else { return nil }
        let filled = CMSampleBufferSetDataBufferFromAudioBufferList(piece, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: heard.audioBufferList)
        return filled == noErr ? piece : nil
    }

    private func measure(_ heard: AVAudioPCMBuffer) {
        guard checking, heard.frameLength > 0, let samples = heard.floatChannelData?[0] else { return }
        let window = max(1, Int(heard.format.sampleRate / 20))
        var levels: [Double] = []
        for i in 0..<Int(heard.frameLength) {
            squares += samples[i] * samples[i]
            counted += 1
            guard counted >= window else { continue }
            let decibels = 10 * log10(max(squares / Float(counted), 1e-12))
            let level = (decibels + 55) / 50 // -55 dB is silence, -5 dB full height (Recorder.swift, quietest and loudest)
            levels.append(level.isFinite ? Double(min(max(level, 0), 1)) : 0)
            squares = 0
            counted = 0
        }
        guard !levels.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onLevels?(levels) }
    }
}
