import AVFoundation
import Foundation

// Studio's voice polish: what is done to the sound of a recording so that it sits right on YouTube.
//
//  1. a high-pass filter takes out the rumble below the voice (a tablet on a desk, a breath on the microphone);
//  2. a gentle compressor evens out loud and quiet words, so the quiet ones are not lost and the loud ones do not jump;
//  3. the whole is raised or lowered to the loudness YouTube plays at (-16 LUFS, a little under its -14 reference,
//     the usual choice for speech), measured the way broadcasters do it (ITU-R BS.1770: K-weighted, gated);
//  4. a soft limiter keeps the peaks below full scale, so that raising it never clips.
//
// The recording is read twice, a piece at a time (an hour of sound never sits in memory): once to measure
// what the chain makes of it, and once to write it with the gain that reaches the target.

// MARK: Filters

private struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    /// From the usual "audio EQ cookbook" forms, divided through by a0.
    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0; self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    static func highPass(_ f: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * f / rate, c = cos(w), alpha = sin(w) / (2 * q)
        return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    static func highShelf(_ f: Double, gainDb: Double, q: Double, rate: Double) -> Biquad {
        let a = pow(10, gainDb / 40), w = 2 * Double.pi * f / rate, c = cos(w), alpha = sin(w) / (2 * q), r = 2 * sqrt(a) * alpha
        return Biquad(b0: a * ((a + 1) + (a - 1) * c + r), b1: -2 * a * ((a - 1) + (a + 1) * c), b2: a * ((a + 1) + (a - 1) * c - r),
                      a0: (a + 1) - (a - 1) * c + r, a1: 2 * ((a - 1) - (a + 1) * c), a2: (a + 1) - (a - 1) * c - r)
    }

    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

// MARK: Loudness

/// Integrated loudness in LUFS, as ITU-R BS.1770-4 defines it: the sound is weighted by two filters that
/// stand in for the ear, its power is taken over 400 ms blocks every 100 ms, and blocks that are silent, or
/// more than 10 LU under the average of the rest, are left out.
struct LoudnessMeter {
    private var shelf: Biquad, high: Biquad
    private let hop: Int
    private var sum = 0.0, count = 0
    private var hops: [Double] = []

    init(rate: Double) {
        shelf = Biquad.highShelf(1681.9744509555319, gainDb: 3.999843853973347, q: 0.7071752369554196, rate: rate)
        high = Biquad.highPass(38.13547087613982, q: 0.5003270373253953, rate: rate)
        hop = max(1, Int(rate / 10))
    }

    mutating func feed(_ x: Float) {
        let y = high.run(shelf.run(Double(x)))
        sum += y * y
        count += 1
        if count == hop {
            hops.append(sum / Double(hop))
            sum = 0
            count = 0
        }
    }

    /// nil: nothing loud enough to measure.
    func integrated() -> Double? {
        guard hops.count >= 4 else { return nil }
        var blocks: [Double] = []
        blocks.reserveCapacity(hops.count)
        for i in 0...(hops.count - 4) {
            var power = 0.0
            for k in 0..<4 { power += hops[i + k] }
            blocks.append(power / 4)
        }
        let loud = { (power: Double) -> Double in -0.691 + 10 * log10(power) }
        let audible = blocks.filter { loud($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let gate = loud(audible.reduce(0, +) / Double(audible.count)) - 10
        let kept = audible.filter { loud($0) > gate }
        guard !kept.isEmpty else { return nil }
        return loud(kept.reduce(0, +) / Double(kept.count))
    }
}

// MARK: The voice chain

/// High-pass, then compressor. Every sample goes through one; it keeps its state from sample to sample.
struct VoiceChain {
    private var rumble: Biquad
    private var envelope = 0.0
    private let attack: Double, release: Double
    private let threshold = -26.0 // dB below full scale
    private let ratio = 2.5
    private let knee = 8.0 // dB

    init(rate: Double) {
        rumble = Biquad.highPass(80, q: 0.7071, rate: rate)
        attack = exp(-1 / (0.008 * rate))   // the level is followed within about 8 ms going up...
        release = exp(-1 / (0.180 * rate))  // ...and lets go over about 180 ms
    }

    mutating func run(_ x: Float) -> Float {
        let y = rumble.run(Double(x))
        let level = abs(y)
        envelope = level > envelope ? attack * envelope + (1 - attack) * level : release * envelope + (1 - release) * level
        let db = 20 * log10(max(envelope, 1e-6))
        let over = db - threshold
        var reduction = 0.0 // dB to take off
        if 2 * over > knee {
            reduction = over * (1 - 1 / ratio)
        } else if 2 * over > -knee {
            reduction = (1 - 1 / ratio) * pow(over + knee / 2, 2) / (2 * knee)
        }
        return Float(y * pow(10, -reduction / 20))
    }
}

/// Keeps peaks under full scale without the harshness of cutting them off: below 0.85 nothing changes; above, the
/// signal bends towards 0.99.
@inline(__always) func softLimit(_ x: Float) -> Float {
    let a = abs(x), knee: Float = 0.85
    guard a > knee else { return x }
    return (x < 0 ? -1 : 1) * (knee + (0.99 - knee) * tanh((a - knee) / (0.99 - knee)))
}

// MARK: The work

enum AudioPolish {
    static let rate = 44_100.0
    static let target = -16.0 // LUFS

    struct Outcome {
        let file: URL
        let before: Double? // LUFS of the voice chain's output before the gain, nil if silent
        let gain: Double    // dB applied
    }

    /// Read the sound of `asset` piece by piece as mono floats at 44.1 kHz and give each piece to `piece`.
    /// Throws what the reader says if it cannot. Not on the main thread: it can take seconds.
    static func read(_ asset: AVAsset, track: AVAssetTrack, range: CMTimeRange?, _ piece: (UnsafeBufferPointer<Float>) -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        if let range = range { reader.timeRange = range }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        guard reader.canAdd(output) else { throw NSError(domain: "EngiNote", code: 10, userInfo: [NSLocalizedDescriptionKey: "the sound could not be read"]) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "EngiNote", code: 11, userInfo: [NSLocalizedDescriptionKey: "the sound could not be read"]) }
        var floats: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            floats = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            if status == kCMBlockBufferNoErr { floats.withUnsafeBufferPointer(piece) }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "EngiNote", code: 12, userInfo: [NSLocalizedDescriptionKey: "the sound could not be read"]) }
    }

    /// The polished sound of the first audio track of `asset` (from `range`, or all of it) as an .m4a in the
    /// temporary folder; nil if there is no sound. `progress` goes from 0 to 1.
    static func process(_ asset: AVAsset, range: CMTimeRange? = nil, progress: (Double) -> Void) async throws -> Outcome? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let length: CMTime
        if let range = range { length = range.duration } else { length = try await asset.load(.duration) }
        let total = length.seconds * rate
        guard total > 0 else { return nil }

        // First pass: how loud is the voice after the chain?
        var chain = VoiceChain(rate: rate), meter = LoudnessMeter(rate: rate), done = 0.0
        try read(asset, track: track, range: range) { block in
            for x in block { meter.feed(chain.run(x)) }
            done += Double(block.count)
            progress(min(0.5, done / total / 2))
        }
        let before = meter.integrated()
        // Not more than +18 dB (a recording that is nearly silent must not become a wall of hiss), nor more than 12 down.
        let gain = before.map { min(18, max(-12, target - $0)) } ?? 0
        let factor = Float(pow(10, gain / 20))

        // Second pass: write it.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: out, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        chain = VoiceChain(rate: rate)
        done = 0
        var failure: Error?
        try read(asset, track: track, range: range) { block in
            guard failure == nil, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            for (i, x) in block.enumerated() { channel[i] = softLimit(chain.run(x) * factor) }
            buffer.frameLength = AVAudioFrameCount(block.count)
            do { try file?.write(from: buffer) } catch { failure = error }
            done += Double(block.count)
            progress(0.5 + min(0.5, done / total / 2))
        }
        file = nil // closing it is what finishes the .m4a
        if let failure = failure { throw failure }
        return Outcome(file: out, before: before, gain: gain)
    }

    /// The loudness of the first audio track, for a test or a report.
    static func loudness(of asset: AVAsset) async throws -> Double? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        var meter = LoudnessMeter(rate: rate)
        try read(asset, track: track, range: nil) { block in for x in block { meter.feed(x) } }
        return meter.integrated()
    }
}
