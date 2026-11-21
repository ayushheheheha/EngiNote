import AVFoundation
import AVKit
import UIKit

/// The camera bubble, for recording other apps: the front camera in a Picture-in-Picture window, which iPadOS floats
/// over every app (and so it is in the recording). Its play/pause button pauses and resumes the recording. Drag it
/// anywhere; pinch to resize; push it off the side to hide it (then it is not in the picture).
///
/// With the camera off, or when iPadOS stops the camera because the app is not in front (allowed only on iPads that
/// support multitasking camera access), the window shows the recording's clock instead, so pause still works.
///
/// Unverified off the device: written against the documentation.
final class Bubble: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// The view the window comes out of: it must be on the screen (Home shows it as a small preview).
    let view = Screen()
    /// Set by Recording on the main thread; read wherever AVKit asks.
    var paused = false
    var clockText = ""
    /// The window's play/pause button was tapped: pause (true) or resume. Called on the main thread.
    var setPaused: (Bool) -> Void = { _ in }
    /// What went wrong, for the notice at the foot of the screen.
    var onProblem: (String) -> Void = { _ in }

    final class Screen: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var film: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    private var pip: AVPictureInPictureController?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.engikode.recorder.camera")
    private var configured = false // touched on `queue`
    private var turner: AVCaptureDevice.RotationCoordinator?
    private var turning: NSKeyValueObservation?
    private var ticker: Timer?
    private let lock = NSLock()
    private var cameraAt = 0.0 // when the camera last gave a frame (uptime)

    override init() {
        super.init()
        view.film.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
    }

    /// Ready the window once the view is on the screen.
    func prepare() {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let p = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: view.film, playbackDelegate: self))
        p.canStartPictureInPictureAutomaticallyFromInline = false // only while recording: enable(true)
        p.requiresLinearPlayback = true // no skip buttons: play/pause only
        pip = p
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    /// Whether the window opens by itself when the app leaves the screen (the Bubble setting is not Off).
    func enable(_ on: Bool) {
        if on { prepare() }
        pip?.canStartPictureInPictureAutomaticallyFromInline = on
        if !on { close() }
    }

    func close() { pip?.stopPictureInPicture() }

    /// The recording paused or resumed: the window's button follows.
    func refresh() {
        pip?.invalidatePlaybackState()
        tick()
    }

    // MARK: the camera

    func camera(_ on: Bool) {
        guard on else {
            queue.async { self.session.stopRunning() }
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { allowed in
            guard allowed else { return DispatchQueue.main.async { self.onProblem("The camera is not allowed: Settings > EngiNote Recorder > Camera.") } }
            self.queue.async { self.start() }
        }
    }

    // On `queue`.
    private func start() {
        if !configured {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                return DispatchQueue.main.async { self.onProblem("The front camera could not be opened.") }
            }
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            if let link = output.connection(with: .video) {
                link.automaticallyAdjustsVideoMirroring = false
                link.isVideoMirrored = true // as in a mirror, like the EngiNote camera bubble
            }
            // Keep the camera on while other apps are in front, where the iPad allows it.
            if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
            session.commitConfiguration()
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            turner = coordinator
            let turn = {
                guard let link = output.connection(with: .video) else { return }
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if link.isVideoRotationAngleSupported(angle) { link.videoRotationAngle = angle }
            }
            turn()
            turning = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture) { _, _ in self.queue.async { turn() } }
            configured = true
        }
        if !session.isRunning { session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        cameraAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        show(buffer)
    }

    // MARK: what the window shows

    private func show(_ buffer: CMSampleBuffer) {
        if let list = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true), CFArrayGetCount(list) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = view.film.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(buffer)
    }

    /// Twice a second: if the camera has given nothing for a second, show the clock.
    private func tick() {
        lock.lock()
        let quiet = ProcessInfo.processInfo.systemUptime - cameraAt > 1
        lock.unlock()
        guard quiet, let frame = clockFrame() else { return }
        show(frame)
    }

    /// A 16:9 frame: a red dot (grey when paused) and the time.
    private func clockFrame() -> CMSampleBuffer? {
        let w = 480, h = 270
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &pixels)
        guard let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let c = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            c.setFillColor(UIColor.black.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.translateBy(x: 0, y: CGFloat(h))
            c.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(c)
            (paused ? UIColor.systemGray : UIColor.systemRed).setFill()
            UIBezierPath(ovalIn: CGRect(x: 40, y: 111, width: 48, height: 48)).fill()
            let words = NSAttributedString(string: paused ? "Paused  " + clockText : clockText, attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 64, weight: .semibold), .foregroundColor: UIColor.white,
            ])
            words.draw(at: CGPoint(x: 112, y: 135 - words.size().height / 2))
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &out)
        return out
    }

    // MARK: the window's buttons

    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        DispatchQueue.main.async {
            self.setPaused(!playing)
            c.invalidatePlaybackState()
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) // live: no timeline
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { paused }

    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) { completion() }
}
