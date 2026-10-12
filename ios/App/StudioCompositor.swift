import AVFoundation
import CoreImage
import CoreGraphics
import CoreText

// Studio's picture: every frame of the finished video is drawn here, from the frame of the recording, one at a
// time, on the GPU (Core Image). The same code draws the main video (the recording, zoomed where the pen is
// writing, between an intro and an outro) and the vertical short.
//
// All of it is plain geometry: a crop of the recording's frame, scaled to the canvas. Core Image's origin is
// the bottom left; the plan and the sidecar speak from the top left, and the conversion is made in one place each.

/// What one render shares between all its frames.
final class StudioJob {
    let sidecar: Sidecar?
    let plan: ZoomPlan?
    let title: String
    let canvas: CGSize
    let sourceSize: CGSize
    let shortStart: Double
    let shortLength: Double

    init(sidecar: Sidecar?, plan: ZoomPlan?, title: String, canvas: CGSize, sourceSize: CGSize, shortStart: Double = 0, shortLength: Double = 1) {
        self.sidecar = sidecar
        self.plan = plan
        self.title = title
        self.canvas = canvas
        self.sourceSize = sourceSize
        self.shortStart = shortStart
        self.shortLength = max(0.1, shortLength)
    }

    // The colour of the note's paper next to the bubble: what is painted over the bubble's zoomed-in ghost. Found once.
    fileprivate var patch: CIColor?
    fileprivate lazy var shortOverlay: CIImage = StudioFrame.makeOverlay(self)
}

/// One stretch of the finished video and how it is drawn.
final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    enum Kind { case clip, main, short }

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let kind: Kind
    let job: StudioJob
    let trackID: CMPersistentTrackID
    /// Seconds to add to the finished video's time to get the recording's time.
    let shift: Double
    let transform: CGAffineTransform

    init(range: CMTimeRange, kind: Kind, job: StudioJob, trackID: CMPersistentTrackID, shift: Double, transform: CGAffineTransform = .identity) {
        timeRange = range
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
        self.kind = kind
        self.job = job
        self.trackID = trackID
        self.shift = shift
        self.transform = transform
        super.init()
    }
}

final class StudioCompositor: NSObject, AVVideoCompositing {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "com.engikode.enginote.studio.frames", qos: .userInitiated)
    private static let pixels: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    var sourcePixelBufferAttributes: [String: Any]? { StudioCompositor.pixels }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { StudioCompositor.pixels }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? StudioInstruction,
                      let source = request.sourceFrame(byTrackID: instruction.trackID),
                      let target = request.renderContext.newPixelBuffer() else {
                    request.finish(with: NSError(domain: "EngiNote", code: 20, userInfo: [NSLocalizedDescriptionKey: "a frame could not be drawn"]))
                    return
                }
                var image = CIImage(cvPixelBuffer: source)
                if !instruction.transform.isIdentity {
                    image = image.transformed(by: instruction.transform)
                }
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                let t = request.compositionTime.seconds + instruction.shift
                let frame = StudioFrame.draw(instruction.kind, source: image, t: t, job: instruction.job, context: StudioCompositor.context)
                let box = CGRect(origin: .zero, size: instruction.job.canvas)
                StudioCompositor.context.render(frame, to: target, bounds: box, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                request.finish(withComposedVideoFrame: target)
            }
        }
    }
}

enum StudioFrame {
    // The site's colours (assets/css/styles.css).
    static let ink = CIColor(red: 0x17 / 255, green: 0x26 / 255, blue: 0x20 / 255)
    static let lime = CIColor(red: 0xdf / 255, green: 0xff / 255, blue: 0x72 / 255)

    static func draw(_ kind: StudioInstruction.Kind, source: CIImage, t: Double, job: StudioJob, context: CIContext) -> CIImage {
        switch kind {
        case .clip: return clip(source, canvas: job.canvas)
        case .main: return main(source, t: t, job: job, context: context)
        case .short: return short(source, t: t, job: job, context: context)
        }
    }

    // MARK: Small helpers

    /// A white rounded rectangle on nothing, to cut an image to.
    static func roundedMask(_ rect: CGRect, radius: CGFloat) -> CIImage {
        let r = min(max(0, radius), min(rect.width, rect.height) / 2)
        if let made = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": r, "inputColor": CIColor.white,
        ])?.outputImage {
            return made.cropped(to: rect)
        }
        return CIImage(color: .white).cropped(to: rect) // a plain rectangle, if the system has no such generator
    }

    /// `top` over `bottom`, cut to `mask`'s shape.
    static func place(_ top: CIImage, over bottom: CIImage, mask: CIImage) -> CIImage {
        top.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: bottom, kCIInputMaskImageKey: mask])
    }

    /// An image of `size` from `source`'s `rect` (Core Image coordinates), filling it exactly.
    static func fill(_ source: CIImage, rect: CGRect, size: CGSize) -> CIImage {
        source.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / rect.width, y: size.height / rect.height))
    }

    /// The crop `c` (fractions from the top left) as a rectangle of a source `size` px, from the bottom left.
    static func rect(of c: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: c.minX * size.width, y: (1 - c.maxY) * size.height, width: c.width * size.width, height: c.height * size.height)
    }

    // MARK: Intro, outro

    /// The whole of `source`, as large as fits, in the middle of the canvas, on the site's ink green.
    static func clip(_ source: CIImage, canvas: CGSize) -> CIImage {
        let s = min(canvas.width / source.extent.width, canvas.height / source.extent.height)
        let w = source.extent.width * s, h = source.extent.height * s
        let placed = source.transformed(by: CGAffineTransform(scaleX: s, y: s)).transformed(by: CGAffineTransform(translationX: (canvas.width - w) / 2, y: (canvas.height - h) / 2))
        return placed.composited(over: CIImage(color: ink).cropped(to: CGRect(origin: .zero, size: canvas)))
    }

    // MARK: The bubble

    /// The paper's colour beside the bubble: the average of a thin ring just outside it.
    static func paper(_ source: CIImage, around r: CGRect, context: CIContext) -> CIColor {
        let box = source.extent, t: CGFloat = 6
        let ring = r.insetBy(dx: -t - 2, dy: -t - 2)
        let strips = [
            CGRect(x: ring.minX, y: ring.minY, width: ring.width, height: t), CGRect(x: ring.minX, y: ring.maxY - t, width: ring.width, height: t),
            CGRect(x: ring.minX, y: ring.minY, width: t, height: ring.height), CGRect(x: ring.maxX - t, y: ring.minY, width: t, height: ring.height),
        ].map { $0.intersection(box) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        var red = 0.0, green = 0.0, blue = 0.0
        for strip in strips {
            guard let average = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: source, "inputExtent": CIVector(cgRect: strip)])?.outputImage else { continue }
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            red += Double(pixel[0]); green += Double(pixel[1]); blue += Double(pixel[2])
        }
        let n = Double(max(1, strips.count)) * 255
        return CIColor(red: red / n, green: green / n, blue: blue / n)
    }

    /// Paint over the zoomed copy of the camera bubble, so that the note does not carry a moving face about. `crop`
    /// is what of the recording the image is (fractions from the top left), `size` the image's size.
    static func hideGhost(_ image: CIImage, bubble b: (rect: CGRect, radius: Double), crop c: CGRect, size: CGSize, colour: CIColor) -> CIImage {
        let h = CGFloat(4)
        let ghost = CGRect(
            x: (b.rect.minX - c.minX) / c.width * size.width - h,
            y: size.height - (b.rect.maxY - c.minY) / c.height * size.height - h,
            width: b.rect.width / c.width * size.width + 2 * h, height: b.rect.height / c.height * size.height + 2 * h)
        guard ghost.intersects(CGRect(origin: .zero, size: size)) else { return image }
        let radius = CGFloat(b.radius / Double(c.width)) * size.width + h
        return place(CIImage(color: colour).cropped(to: ghost), over: image, mask: roundedMask(ghost, radius: radius))
    }

    // MARK: The main video

    static func main(_ source: CIImage, t: Double, job: StudioJob, context: CIContext) -> CIImage {
        let canvas = job.canvas, size = source.extent.size
        var image = source
        if let plan = job.plan {
            let c = plan.crop(at: t, canvas: Double(canvas.width / canvas.height), source: Double(size.width / size.height))
            if c.width < 0.995 || c.height < 0.995 {
                image = fill(source, rect: rect(of: c, in: size), size: canvas)
                // The camera bubble is part of the recording, so zooming moves it: it is put back where it was, and the
                // copy that went with the note is painted out.
                if let bubble = job.sidecar?.bubble(at: t) {
                    if job.patch == nil { job.patch = paper(source, around: rect(of: bubble.rect, in: size), context: context) }
                    image = hideGhost(image, bubble: bubble, crop: c, size: canvas, colour: job.patch!)
                    let spot = rect(of: bubble.rect, in: size)
                    let home = CGRect(x: spot.minX * canvas.width / size.width, y: spot.minY * canvas.height / size.height,
                                      width: spot.width * canvas.width / size.width, height: spot.height * canvas.height / size.height)
                    let radius = CGFloat(bubble.radius) * canvas.width
                    image = place(fill(source, rect: spot, size: home.size).transformed(by: CGAffineTransform(translationX: home.minX, y: home.minY)),
                                  over: image, mask: roundedMask(home, radius: radius))
                }
            }
        }
        return image.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    // MARK: The short

    static let shortFace = CGRect(x: 70, y: 290, width: 340, height: 340)

    static func short(_ source: CIImage, t: Double, job: StudioJob, context: CIContext) -> CIImage {
        let canvas = job.canvas, size = source.extent.size
        let cardRect = CGRect(x: 40, y: canvas.height - 200 - 1000, width: 1000, height: 1000) // 200 px from the top, a square of 1000
        let c = job.plan?.crop(at: t, canvas: 1, source: Double(size.width / size.height))
            ?? ZoomPlan(path: [], duration: 0, canvas: 1, source: Double(size.width / size.height)).crop(at: 0, canvas: 1, source: Double(size.width / size.height))
        var note = fill(source, rect: rect(of: c, in: size), size: cardRect.size)
        let bubble = job.sidecar?.bubble(at: t)
        if let bubble = bubble {
            if job.patch == nil { job.patch = paper(source, around: rect(of: bubble.rect, in: size), context: context) }
            note = hideGhost(note, bubble: bubble, crop: c, size: cardRect.size, colour: job.patch!)
        }
        var image = job.shortOverlay
        image = place(note.transformed(by: CGAffineTransform(translationX: cardRect.minX, y: cardRect.minY)), over: image, mask: roundedMask(cardRect, radius: 30))
        if let bubble = bubble {
            // The face: the middle square of the bubble, as a circle.
            let spot = rect(of: bubble.rect, in: size), side = min(spot.width, spot.height)
            let square = CGRect(x: spot.midX - side / 2, y: spot.midY - side / 2, width: side, height: side)
            let face = shortFace
            image = place(fill(source, rect: square, size: face.size).transformed(by: CGAffineTransform(translationX: face.minX, y: face.minY)),
                          over: image, mask: roundedMask(face, radius: face.width / 2))
        }
        // The progress bar along the foot.
        let done = min(1, max(0, (t - job.shortStart) / job.shortLength))
        if done > 0.002 {
            let bar = CGRect(x: 80, y: 80, width: 920 * done, height: 10)
            image = place(CIImage(color: lime).cropped(to: bar), over: image, mask: roundedMask(bar, radius: 5))
        }
        return image.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    // MARK: The short's page: everything that does not move

    /// Text on one line at a point (Core Graphics coordinates, from the bottom left).
    private static func line(_ ctx: CGContext, _ text: String, font: String, size: CGFloat, at p: CGPoint, color: CGColor, tracking: CGFloat = 0) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking,
        ]
        ctx.textPosition = p
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), ctx)
    }

    /// Text wrapped to `width`, at most `lines` lines, the first line's top at `top` px from the top.
    private static func paragraph(_ ctx: CGContext, _ text: String, font: String, size: CGFloat, x: CGFloat, top: CGFloat, width: CGFloat, lines: Int, color: CGColor, height: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let setter = CTTypesetterCreateWithAttributedString(string)
        var start = 0, row = 0
        while start < string.length, row < lines {
            var count = CTTypesetterSuggestLineBreak(setter, start, Double(width))
            if count <= 0 { break }
            var made = CTTypesetterCreateLine(setter, CFRange(location: start, length: count))
            if row == lines - 1, start + count < string.length { // the last line is cut short with "…"
                let end = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                if let cut = CTLineCreateTruncatedLine(made, Double(width), .end, end) { made = cut }
                count = string.length - start
            }
            ctx.textPosition = CGPoint(x: x, y: height - top - size * (0.95 + 1.12 * CGFloat(row)))
            CTLineDraw(made, ctx)
            start += count
            row += 1
        }
    }

    /// The page of the short, behind the note and the face: the site's ink green with its lime and cream, the channel and
    /// the title. Drawn once.
    static func makeOverlay(_ job: StudioJob) -> CIImage {
        let w = Int(job.canvas.width), h = Int(job.canvas.height), H = CGFloat(h)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage(color: ink).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)) }
        let inkC = CGColor(srgbRed: 0x17 / 255, green: 0x26 / 255, blue: 0x20 / 255, alpha: 1)
        let ink2C = CGColor(srgbRed: 0x2d / 255, green: 0x44 / 255, blue: 0x38 / 255, alpha: 1)
        let limeC = CGColor(srgbRed: 0xdf / 255, green: 0xff / 255, blue: 0x72 / 255, alpha: 1)
        let creamC = CGColor(srgbRed: 1, green: 0xfd / 255, blue: 0xf7 / 255, alpha: 1)
        let coralC = CGColor(srgbRed: 0xf6 / 255, green: 0x8b / 255, blue: 0x72 / 255, alpha: 1)
        let faintC = CGColor(srgbRed: 0xb0 / 255, green: 0xc0 / 255, blue: 0xb5 / 255, alpha: 1)

        // Ground, with two circles in it as on the site's dark band.
        ctx.setFillColor(inkC)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(ink2C)
        ctx.fillEllipse(in: CGRect(x: 560, y: H - 620, width: 760, height: 760))
        ctx.setStrokeColor(CGColor(srgbRed: 0xdf / 255, green: 0xff / 255, blue: 0x72 / 255, alpha: 0.28))
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: -150, y: 90, width: 420, height: 420))

        // The brand, top left: the mark in its tilted lime box, and the name.
        ctx.saveGState()
        ctx.translateBy(x: 70 + 34, y: H - 70 - 34)
        ctx.rotate(by: .pi / 30)
        ctx.setFillColor(limeC)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -34, y: -34, width: 68, height: 68), cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(inkC)
        let k: CGFloat = 0.1 // the mark is 457 wide in its own units
        ctx.scaleBy(x: k, y: -k)
        ctx.translateBy(x: -457.26 / 2, y: -304.89 / 2)
        ctx.move(to: CGPoint(x: 457.26, y: 0)); ctx.addLine(to: CGPoint(x: 378.29, y: 0)); ctx.addLine(to: CGPoint(x: 197.77, y: 243.9))
        ctx.addLine(to: CGPoint(x: 197.78, y: 304.89)); ctx.addLine(to: CGPoint(x: 430.53, y: 304.88)); ctx.addLine(to: CGPoint(x: 330.01, y: 182.91)); ctx.closePath()
        ctx.addRect(CGRect(x: 0, y: 121.95, width: 197.77, height: 60.98))
        ctx.addRect(CGRect(x: 0, y: 243.9, width: 263.68, height: 60.99))
        ctx.addRect(CGRect(x: 0, y: 0, width: 197.77, height: 60.98))
        ctx.fillPath()
        ctx.restoreGState()
        line(ctx, "ENGIKODE", font: "AvenirNext-Heavy", size: 40, at: CGPoint(x: 160, y: H - 118), color: creamC, tracking: 5)
        line(ctx, "EXPLAINED WITHOUT THE NOISE", font: "Menlo-Regular", size: 20, at: CGPoint(x: 160, y: H - 154), color: faintC, tracking: 2)

        // The note's card: the site's hard offset shadow, in limeC.
        let card = CGRect(x: 40, y: H - 200 - 1000, width: 1000, height: 1000)
        ctx.setFillColor(limeC)
        ctx.addPath(CGPath(roundedRect: card.offsetBy(dx: 14, dy: -14), cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(creamC)
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.fillPath()

        // Under the card: the face (with a ring) and the title, or the title across when there is no face.
        let face = shortFace
        let hasFace = job.sidecar?.hadBubble ?? false
        if hasFace {
            ctx.setStrokeColor(limeC)
            ctx.setLineWidth(8)
            ctx.strokeEllipse(in: face.insetBy(dx: -8, dy: -8))
        }
        let x: CGFloat = hasFace ? 450 : 70
        line(ctx, "LEARN WITH ENGIKODE", font: "Menlo-Regular", size: 22, at: CGPoint(x: x, y: H - 1296 - 22), color: limeC, tracking: 3)
        paragraph(ctx, job.title, font: "Georgia-BoldItalic", size: 56, x: x, top: 1336, width: 1010 - x, lines: 3, color: creamC, height: H)

        // The channel, as a button.
        let button = CGRect(x: 70, y: 150, width: 940, height: 92)
        ctx.setFillColor(limeC)
        ctx.addPath(CGPath(roundedRect: button, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(coralC)
        ctx.fillEllipse(in: CGRect(x: button.minX + 28, y: button.midY - 24, width: 48, height: 48))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.move(to: CGPoint(x: button.minX + 46, y: button.midY + 12))
        ctx.addLine(to: CGPoint(x: button.minX + 46, y: button.midY - 12))
        ctx.addLine(to: CGPoint(x: button.minX + 64, y: button.midY))
        ctx.closePath()
        ctx.fillPath()
        line(ctx, "Subscribe on YouTube  @EngiKode", font: "AvenirNext-Heavy", size: 34, at: CGPoint(x: button.minX + 100, y: button.midY - 12), color: inkC)
        line(ctx, "engikode.vercel.app", font: "Menlo-Regular", size: 24, at: CGPoint(x: 72, y: 112), color: faintC, tracking: 1)

        // The track the progress bar runs along.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 80, y: 80, width: 920, height: 10), cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()

        guard let picture = ctx.makeImage() else { return CIImage(color: StudioFrame.ink).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)) }
        return CIImage(cgImage: picture)
    }
}
