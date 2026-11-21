import AVFoundation

/// Joins a recording's two halves (the extension's picture and app sound, the app's voice) into one movie in Documents.
/// The picture is copied as it is (no second encode, so it is quick and loses nothing); the sounds are mixed into one
/// track, because many players and editors play only a movie's first sound track.
enum Joiner {
    /// How loud the sound of other apps is put under the voice (1: as recorded): the knob if it drowns the voice.
    static let appVolume: Float = 0.8

    static func join(_ id: String, into movie: URL) async throws {
        guard let raw = Shared.folder else { throw failure("the shared folder is missing") }
        let screen = AVURLAsset(url: raw.appendingPathComponent("\(id).screen.mov"))
        guard let picture = try await screen.loadTracks(withMediaType: .video).first else { throw failure("the recording has no picture") }
        let length = try await screen.load(.duration)

        // The sounds, placed against the picture: each half's time 0 is a moment on the device's clock (Part.start).
        let mix = AVMutableComposition()
        var levels: [AVMutableAudioMixInputParameters] = []
        func place(_ track: AVAssetTrack, at offset: Double, volume: Float) async throws {
            let range = try await track.load(.timeRange)
            let lead = CMTime(seconds: max(0, -offset), preferredTimescale: 48_000)
            let at = CMTime(seconds: max(0, offset), preferredTimescale: 48_000)
            let fits = CMTimeMinimum(CMTimeSubtract(range.duration, lead), CMTimeSubtract(length, at))
            guard fits > .zero, let into = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
            try into.insertTimeRange(CMTimeRange(start: CMTimeAdd(range.start, lead), duration: fits), of: track, at: at)
            let p = AVMutableAudioMixInputParameters(track: into)
            p.setVolume(volume, at: .zero)
            levels.append(p)
        }
        // The extension's own sound: the apps', and ReplayKit's microphone when the app was not writing the voice.
        for track in try await screen.loadTracks(withMediaType: .audio) {
            try await place(track, at: 0, volume: appVolume)
        }
        let voiceFile = raw.appendingPathComponent("\(id).voice.mov")
        if FileManager.default.fileExists(atPath: voiceFile.path), let s = Part.load(id, "screen")?.start, let v = Part.load(id, "voice")?.start,
           let voice = try await AVURLAsset(url: voiceFile).loadTracks(withMediaType: .audio).first {
            try await place(voice, at: v - s, volume: 1)
        }

        try? FileManager.default.removeItem(at: movie)
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let picIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: try await picture.load(.formatDescriptions).first)
        picIn.transform = try await picture.load(.preferredTransform)
        writer.add(picIn)
        let picReader = try AVAssetReader(asset: screen)
        let picOut = AVAssetReaderTrackOutput(track: picture, outputSettings: nil)
        picReader.add(picOut)

        var soundReader: AVAssetReader?
        var soundOut: AVAssetReaderAudioMixOutput?
        var soundIn: AVAssetWriterInput?
        let sounds = mix.tracks(withMediaType: .audio)
        if !sounds.isEmpty {
            let r = try AVAssetReader(asset: mix)
            let o = AVAssetReaderAudioMixOutput(audioTracks: sounds, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            let m = AVMutableAudioMix()
            m.inputParameters = levels
            o.audioMix = m
            r.add(o)
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000])
            writer.add(i)
            (soundReader, soundOut, soundIn) = (r, o, i)
        }

        guard writer.startWriting(), picReader.startReading(), soundReader?.startReading() ?? true else {
            throw writer.error ?? picReader.error ?? soundReader?.error ?? failure("the movie could not be started")
        }
        writer.startSession(atSourceTime: .zero)
        async let a: Void = pump(picOut, into: picIn, label: "picture")
        if let soundOut, let soundIn { await pump(soundOut, into: soundIn, label: "sound") }
        await a
        writer.endSession(atSourceTime: length)
        await writer.finishWriting()
        if let e = picReader.error ?? soundReader?.error ?? writer.error, writer.status != .completed || picReader.status == .failed {
            throw e
        }
        guard writer.status == .completed else { throw failure("the movie could not be finished") }
    }

    /// Copy everything `from` gives into `into`, then close it.
    private static func pump(_ from: AVAssetReaderOutput, into: AVAssetWriterInput, label: String) async {
        let queue = DispatchQueue(label: "com.engikode.recorder.join." + label)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            into.requestMediaDataWhenReady(on: queue) {
                while into.isReadyForMoreMediaData {
                    guard let piece = from.copyNextSampleBuffer(), into.append(piece) else {
                        into.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
    }

    private static func failure(_ why: String) -> NSError {
        NSError(domain: "EngiNoteRecorder", code: 10, userInfo: [NSLocalizedDescriptionKey: why])
    }
}
