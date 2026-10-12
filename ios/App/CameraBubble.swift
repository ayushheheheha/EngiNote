import AVFoundation
import UIKit

/// The camera bubble: the front camera's picture in a small view that floats over the app, so
/// whoever is teaching can be in the video too. One finger drags it anywhere on the screen, two
/// pinch it larger or smaller, and a double tap (or the page's button) gives it the next of its
/// four shapes. Where it is, how big it is and its shape are remembered.
///
/// It is a view of the app's own, above the web view, because a page in this app cannot use the
/// camera. Being on the screen it is in a recording of the screen (in a 16:9 recording: as far as
/// it lies over the 16:9 window; it may be put anywhere, that window or not).
///
/// It has nothing to do with sound. The camera session is given no microphone and is told to leave
/// the app's audio alone, so the voice of a recording (Recorder.swift) is never touched by it.
///
/// None of this can be run off the device: it was written against the documentation and is only
/// proven on the iPad.
final class CameraBubble: UIView, UIGestureRecognizerDelegate {
    /// The names the page uses (app.js, SHAPES): they must match.
    static let shapes = ["circle", "square", "wide", "tall"]

    /// Called on the main thread with every outcome the page should know: whether the bubble is
    /// showing, and, when it was asked for and is not, why.
    var onNews: ((_ on: Bool, _ problem: String?) -> Void)?

    private(set) var shape = "circle"
    private var side: CGFloat = 180 // its longer side, in points
    // Its middle, as fractions of the screen's width and height, so that it keeps its corner when
    // the iPad is turned. To begin with: at the right, inside the 16:9 window either way up.
    private var spot = CGPoint(x: 0.84, y: 0.6)
    private var wanted = false // asked for, and not since switched off

    private let picture = Picture()
    private let session = AVCaptureSession()
    // Setting the session up, starting it and stopping it all take a while: never on the main thread.
    private let queue = DispatchQueue(label: "com.engikode.enginote.camera")
    private var ready = false // the session has its camera (touched on `queue` only)
    private var turner: AVCaptureDevice.RotationCoordinator?
    private var turning: NSKeyValueObservation?

    /// A view whose layer is the camera's picture, so that the picture is always exactly its size.
    private final class Picture: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var film: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    init() {
        super.init(frame: .zero)
        let saved = UserDefaults.standard
        if let shape = saved.string(forKey: "cameraShape"), CameraBubble.shapes.contains(shape) { self.shape = shape }
        if let side = saved.object(forKey: "cameraSide") as? Double, side.isFinite { self.side = CGFloat(side) }
        if let x = saved.object(forKey: "cameraX") as? Double, let y = saved.object(forKey: "cameraY") as? Double, x.isFinite, y.isFinite {
            spot = CGPoint(x: x, y: y)
        }

        isHidden = true
        clipsToBounds = true // this is what gives the picture its shape
        backgroundColor = .black
        layer.borderWidth = 2 // a light rim, so the bubble stands out from a white note
        layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor

        picture.frame = bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        picture.isUserInteractionEnabled = false
        picture.film.videoGravity = .resizeAspectFill // fill the shape, whatever it is; what does not fit is cut off
        picture.film.session = session
        addSubview(picture)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let taps = UITapGestureRecognizer(target: self, action: #selector(tappedTwice))
        taps.numberOfTapsRequired = 2
        let gestures: [UIGestureRecognizer] = [drag, pinch, taps]
        for gesture in gestures {
            // Fingers only: the Pencil is for writing, and must not drag the bubble about.
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("CameraBubble is made in code")
    }

    // MARK: On and off

    /// Show the bubble. The outcome goes to onNews: on; or off, with the reason (the user said no
    /// to the camera, or there is no front camera to be had).
    func turnOn() {
        wanted = true
        guard isHidden else { // showing already: asked again, with a new shape
            onNews?(true, nil)
            return
        }
        // Asks the user the first time; after that it answers at once with what they said.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self = self else { return }
            guard allowed else {
                DispatchQueue.main.async { self.giveUp("EngiNote is not allowed to use the camera. You can allow it in Settings > EngiNote.") }
                return
            }
            self.queue.async { self.start() }
        }
    }

    func turnOff() {
        wanted = false
        isHidden = true
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        onNews?(false, nil)
    }

    /// The app is on screen again. iPadOS stops the camera of an app that is not, and is meant to
    /// start it again by itself; this makes sure of it.
    func wake() {
        guard wanted, !isHidden else { return }
        queue.async {
            if self.ready, !self.session.isRunning { self.session.startRunning() }
        }
    }

    // On the main thread.
    private func giveUp(_ problem: String) {
        wanted = false
        isHidden = true
        onNews?(false, problem)
    }

    // On `queue`: give the session the front camera, once, and start it.
    // ponytail: a camera that fails later (not at the start) is not noticed: the bubble then shows a
    // still or black picture until it is switched off and on, which starts the camera afresh. Watch
    // for the session's runtime error if that ever happens in practice.
    private func start() {
        if !ready {
            // Which kind the front camera is differs from iPad to iPad: any of them will do.
            let front = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTrueDepthCamera], mediaType: .video, position: .front
            ).devices.first
            guard let camera = front, let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                DispatchQueue.main.async { self.giveUp("The front camera could not be used.") }
                return
            }
            session.beginConfiguration()
            // Picture only: no microphone is added, and the session is not to rearrange the app's
            // audio either. The recorder's listening must stay exactly as it is.
            session.automaticallyConfiguresApplicationAudioSession = false
            session.addInput(input)
            // 1080p: the bubble is drawn at the screen's own sharpness and then shrunk into the video, so a bigger picture comes out cleaner.
            if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
            else if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            // Center Stage: the picture follows the face, so the speaker stays framed while moving about. It is the
            // system's own and the user can still turn it off in Control Centre.
            if camera.activeFormat.isCenterStageSupported {
                AVCaptureDevice.centerStageControlMode = .cooperative
                AVCaptureDevice.isCenterStageEnabled = true
            }
            // iPadOS may show the app in a window beside others, where the camera is otherwise taken away.
            if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
            session.commitConfiguration()
            ready = true
            DispatchQueue.main.async { self.keepUpright(camera) }
        }
        if !session.isRunning { session.startRunning() } // returns once it runs, or has failed to
        let running = session.isRunning
        DispatchQueue.main.async {
            guard running else {
                self.giveUp("The camera could not be started.")
                return
            }
            guard self.wanted else { // switched off again while the camera was starting
                self.queue.async { self.session.stopRunning() }
                return
            }
            self.isHidden = false
            self.place()
            if let turner = self.turner { self.turn(to: turner.videoRotationAngleForHorizonLevelPreview) }
            self.onNews?(true, nil)
        }
    }

    // MARK: The picture's way up

    // The picture is turned to stay upright however the iPad is held: the coordinator knows the
    // angle for this camera and this layer, and says when it changes.
    // (Mirroring needs nothing: a preview of a front camera is mirrored by itself.)
    private func keepUpright(_ camera: AVCaptureDevice) {
        let turner = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: picture.film)
        self.turner = turner
        turn(to: turner.videoRotationAngleForHorizonLevelPreview)
        turning = turner.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            DispatchQueue.main.async { self?.turn(to: angle) }
        }
    }

    private func turn(to angle: CGFloat) {
        // An angle the connection does not take would stop the app: ask first.
        guard let link = picture.film.connection, link.isVideoRotationAngleSupported(angle) else { return }
        link.videoRotationAngle = angle
    }

    // MARK: Place, size and shape

    /// Put the bubble where it belongs, in its shape and size: moved, and made smaller, as far as
    /// it takes for all of it to be on the screen. Called again whenever the screen changes
    /// (the iPad turned, the app's window resized).
    func place() {
        guard let around = superview?.bounds, around.width > 0, around.height > 0 else { return }
        let long = min(max(side, 80), min(around.width, around.height))
        let short = long * 3 / 4
        var size = CGSize(width: long, height: long) // the circle and the square
        if shape == "wide" { size.height = short }
        if shape == "tall" { size.width = short }
        let x = min(max(spot.x * around.width, size.width / 2), around.width - size.width / 2)
        let y = min(max(spot.y * around.height, size.height / 2), around.height - size.height / 2)
        frame = CGRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
        layer.cornerRadius = shape == "circle" ? long / 2 : long * 0.14
    }

    /// Give the bubble this shape, if it is one of the four.
    func reshape(_ name: String) {
        guard CameraBubble.shapes.contains(name), name != shape else { return }
        shape = name
        place()
        remember()
    }

    // After the fingers have moved or resized it: take the place and size it really got (held back
    // at the screen's edges) as the ones wanted, so the next movement starts from what is seen.
    private func settle(_ gesture: UIGestureRecognizer) {
        place()
        if let around = superview?.bounds, around.width > 0, around.height > 0 {
            side = max(frame.width, frame.height)
            spot = CGPoint(x: frame.midX / around.width, y: frame.midY / around.height)
        }
        if gesture.state == .ended || gesture.state == .cancelled { remember() }
    }

    private func remember() {
        let saved = UserDefaults.standard
        saved.set(shape, forKey: "cameraShape")
        saved.set(Double(side), forKey: "cameraSide")
        saved.set(Double(spot.x), forKey: "cameraX")
        saved.set(Double(spot.y), forKey: "cameraY")
    }

    @objc private func dragged(_ drag: UIPanGestureRecognizer) {
        guard let around = superview, around.bounds.width > 0, around.bounds.height > 0 else { return }
        let moved = drag.translation(in: around)
        drag.setTranslation(.zero, in: around)
        spot.x += moved.x / around.bounds.width
        spot.y += moved.y / around.bounds.height
        settle(drag)
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        if pinch.scale.isFinite, pinch.scale > 0 { side *= pinch.scale }
        pinch.scale = 1
        settle(pinch)
    }

    @objc private func tappedTwice() {
        let now = CameraBubble.shapes.firstIndex(of: shape) ?? 0
        reshape(CameraBubble.shapes[(now + 1) % CameraBubble.shapes.count])
        onNews?(true, nil) // the page shows the shape on its button
    }

    // Two fingers both move and resize it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // Only the shape itself is the bubble: a touch in the empty corner beside a circle goes to the note.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).contains(point)
    }
}
