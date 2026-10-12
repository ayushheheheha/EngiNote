import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Tries Studio's pipeline on a Mac, with a recording made up here: a note being written on (a pen that moves
// along three lines), a camera bubble, a quiet voice. Run by .github/workflows/studio.yml, which keeps the pictures
// it saves so they can be looked at. Exits with 1 if something that must hold does not.

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "studio-out", isDirectory: true)
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var failures: [String] = []
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok    " : "FAIL  ", what)
    if !ok { failures.append(what) }
}

// MARK: Making up a recording

let W = 1920, H = 1080, seconds = 6.0, fps = 60
let windowPts = (w: 1366.0, h: 768.0)
let bubblePts = CGRect(x: 1050, y: 470, width: 230, height: 230)

/// Where the pen is `t` seconds in (nil: not writing), in fractions of the picture.
func pen(at t: Double) -> (u: Double, v: Double)? {
    if t >= 0.5 && t < 2.0 { return (0.15 + 0.40 * (t - 0.5) / 1.5, 0.30 + 0.015 * sin(t * 40)) }
    if t >= 2.2 && t < 3.6 { return (0.15 + 0.35 * (t - 2.2) / 1.4, 0.42 + 0.015 * sin(t * 40)) }
    if t >= 4.0 && t < 5.5 { return (0.60 + 0.30 * (t - 4.0) / 1.5, 0.75 + 0.015 * sin(t * 40)) }
    return nil
}

func drawSource(_ ctx: CGContext, t: Double) {
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.99, blue: 0.97, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.88, blue: 0.9, alpha: 1))
    ctx.setLineWidth(2)
    for x in stride(from: 0, to: W, by: 120) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)) }
    for y in stride(from: 0, to: H, by: 120) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)) }
    ctx.strokePath()
    // The writing so far, and the pen.
    ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.15, blue: 0.4, alpha: 1))
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    var started = false
    var step = 0.0
    while step <= t {
        if let p = pen(at: step) {
            let point = CGPoint(x: p.u * Double(W), y: Double(H) - p.v * Double(H))
            if started { ctx.addLine(to: point) } else { ctx.move(to: point); started = true }
        } else { started = false }
        step += 1.0 / 60
    }
    ctx.strokePath()
    if let p = pen(at: t) {
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: p.u * Double(W) - 8, y: Double(H) - p.v * Double(H) - 8, width: 16, height: 16))
    }
    // The camera bubble: a face-coloured disc with two eyes and a white rim.
    let b = CGRect(x: bubblePts.minX / windowPts.w * Double(W), y: Double(H) - bubblePts.maxY / windowPts.h * Double(H),
                   width: bubblePts.width / windowPts.w * Double(W), height: bubblePts.height / windowPts.h * Double(H))
    ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.55, blue: 0.35, alpha: 1))
    ctx.fillEllipse(in: b)
    ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: b.midX - 40, y: b.midY + 10, width: 24, height: 24))
    ctx.fillEllipse(in: CGRect(x: b.midX + 16, y: b.midY + 10, width: 24, height: 24))
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(6)
    ctx.strokeEllipse(in: b)
}

/// A silent-picture movie (or a still colour) of `length` seconds.
func makeMovie(_ url: URL, width: Int, height: Int, fps: Int, length: Double, draw: (CGContext, Double) -> Void) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    let frames = Int(length * Double(fps))
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        draw(ctx, Double(i) / Double(fps))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "test", code: 1) }
}

/// Speech-like: a 180 Hz voice that swells and falls three times a second, some hiss, a 40 Hz rumble. Quiet.
func makeVoice(_ url: URL, length: Double) throws {
    try? FileManager.default.removeItem(at: url)
    let rate = 44_100.0
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1], commonFormat: .pcmFormatFloat32, interleaved: false)
    let count = Int(length * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
    buffer.frameLength = AVAudioFrameCount(count)
    var seed: UInt32 = 7
    for i in 0..<count {
        let t = Double(i) / rate
        seed = seed &* 1664525 &+ 1013904223
        let hiss = Double(seed >> 8) / Double(1 << 24) - 0.5
        let swell = pow(max(0, sin(2 * .pi * 1.5 * t)), 2)
        let voice = sin(2 * .pi * 180 * t) * 0.6 + sin(2 * .pi * 540 * t) * 0.2 + sin(2 * .pi * 1500 * t) * 0.1
        let x = 0.11 * voice * (0.15 + 0.85 * swell) + 0.002 * hiss + 0.01 * sin(2 * .pi * 40 * t)
        buffer.floatChannelData![0][i] = Float(x)
    }
    try file?.write(from: buffer)
    file = nil
}

func png(_ asset: AVAsset, at seconds: Double, to name: String) throws -> CGSize {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    let destination = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return CGSize(width: image.width, height: image.height)
}

// MARK: The test

let work = FileManager.default.temporaryDirectory.appendingPathComponent("studio-test-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

print("making the made-up recording...")
let silent = work.appendingPathComponent("silent.mov"), voice = work.appendingPathComponent("voice.m4a")
try makeMovie(silent, width: W, height: H, fps: fps, length: seconds) { drawSource($0, t: $1) }
try makeVoice(voice, length: seconds)
// Together, as a recording from the iPad is.
let movie = work.appendingPathComponent("Thermodynamics 2026-10-11 14.03.22.mov")
do {
    let together = AVMutableComposition()
    let silentAsset = AVURLAsset(url: silent), voiceAsset = AVURLAsset(url: voice)
    try together.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600)), of: try await silentAsset.loadTracks(withMediaType: .video)[0], at: .zero)
    try together.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600)), of: try await voiceAsset.loadTracks(withMediaType: .audio)[0], at: .zero)
    let session = AVAssetExportSession(asset: together, presetName: AVAssetExportPresetPassthrough)!
    session.outputURL = movie
    session.outputFileType = .mov
    await session.export()
    check(session.status == .completed, "the made-up recording is made (\(session.error?.localizedDescription ?? "ok"))")
}

// What the recorder would have noted.
let started = 1_700_000_000_000.0
var sidecar = Sidecar()
sidecar.startedAt = started
sidecar.window = [0, 0, windowPts.w, windowPts.h]
var step = 0.0
while step < seconds {
    if let p = pen(at: step) { sidecar.pen.append([started + step * 1000, p.u, p.v, 1]) }
    step += 0.05
}
sidecar.bubble = [[started, Double(bubblePts.minX), Double(bubblePts.minY), Double(bubblePts.width), Double(bubblePts.height), 115]]
sidecar.save(for: movie)
check(Sidecar.load(for: movie)?.pen.count == sidecar.pen.count, "the sidecar is saved and read back")
check(abs((sidecar.videoTime(started + 2500) ?? -1) - 2.5) < 0.001, "wall-clock time maps to movie time")
var paused = sidecar
paused.pauses = [[started + 1000, started + 1500]]
check(paused.videoTime(started + 1200) == nil && abs((paused.videoTime(started + 2000) ?? -1) - 1.5) < 0.001, "a pause is left out of movie time")

// The zoom plan.
let plan = ZoomPlan(path: sidecar.penPath(), duration: seconds, canvas: 16.0 / 9, source: 16.0 / 9)
let idle = plan.at(0.1), writing = plan.at(1.6), later = plan.at(4.9)
print(String(format: "camera: t=0.1 z=%.2f  t=1.6 z=%.2f at (%.2f, %.2f)  t=4.9 z=%.2f at (%.2f, %.2f)", idle.z, writing.z, writing.x, writing.y, later.z, later.x, later.y))
check(idle.z < 1.05, "the camera starts on the whole picture")
check(writing.z > 1.25 && writing.y < 0.5, "it comes in on the first line")
check(later.x > 0.5, "it follows the pen to the right")
var smooth = true, last = plan.at(0)
for i in 1..<Int(seconds * 60) {
    let now = plan.at(Double(i) / 60)
    if abs(now.x - last.x) > 0.02 || abs(log(now.z / last.z)) > 0.05 { smooth = false }
    last = now
}
check(smooth, "the camera never jumps from one frame to the next")

// The voice.
let before = try await AudioPolish.loudness(of: AVURLAsset(url: voice)) ?? -99
print(String(format: "voice before: %.1f LUFS", before))
check(before < -25, "the made-up voice is quiet (\(before))")

// The studio.
func clip(_ name: String, red: Double) throws -> URL {
    let url = work.appendingPathComponent(name)
    try makeMovie(url, width: 1280, height: 720, fps: 30, length: 1) { ctx, t in
        ctx.setFillColor(CGColor(srgbRed: red, green: 1, blue: 0.45, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.15, blue: 0.125, alpha: 1))
        ctx.fill(CGRect(x: 100 + t * 600, y: 300, width: 200, height: 100))
    }
    return url
}
let intro = try clip("intro.mov", red: 0.87), outro = try clip("outro.mov", red: 0.96)
var options = StudioOptions()
options.short = true
options.shortStart = 0
options.shortLength = 6
let finished = try await StudioRender.run(movie: movie, options: options, intro: intro, outro: outro, folder: out, cancel: StudioCancel()) { fraction, what in
    if Int(fraction * 100) % 25 == 0 { print(String(format: "  %3.0f%%  %@", fraction * 100, what)) }
}
print("notes:", finished.notes)
check(finished.files.count == 2, "a video and a short are made")
if finished.files.count == 2 {
    let main = AVURLAsset(url: finished.files[0]), short = AVURLAsset(url: finished.files[1])
    let mainLength = try await main.load(.duration).seconds, shortLength = try await short.load(.duration).seconds
    print(String(format: "lengths: video %.2f s, short %.2f s", mainLength, shortLength))
    check(abs(mainLength - (seconds + 2)) < 0.3, "the video is the recording with an intro and an outro")
    check(abs(shortLength - seconds) < 0.3, "the short is as long as asked")
    for (name, at) in [("main-intro.png", 0.5), ("main-writing-1.png", 1.0 + 1.6), ("main-writing-2.png", 1.0 + 3.0), ("main-right.png", 1.0 + 4.9), ("main-outro.png", 1.0 + seconds + 0.5)] {
        let size = try png(main, at: at, to: name)
        if name == "main-intro.png" { check(size == CGSize(width: W, height: H), "the video is \(W) by \(H) (\(size))") }
    }
    for (name, at) in [("short-1.png", 0.3), ("short-2.png", 1.6), ("short-3.png", 3.0), ("short-4.png", 4.9)] {
        let size = try png(short, at: at, to: name)
        if name == "short-1.png" { check(size == CGSize(width: 1080, height: 1920), "the short is 1080 by 1920 (\(size))") }
    }
    let after = try await AudioPolish.loudness(of: main) ?? -99
    print(String(format: "voice after: %.1f LUFS", after))
    check(abs(after - AudioPolish.target) < 1.5, "the voice comes out at about \(AudioPolish.target) LUFS (\(after))")
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: finished.files[0].path)[.size] as? Int) ?? 0
    print("video file:", fileSize / 1000, "KB")
}

try? FileManager.default.removeItem(at: work)
print(failures.isEmpty ? "\nALL GOOD" : "\nFAILED: \(failures.count)")
exit(failures.isEmpty ? 0 : 1)
