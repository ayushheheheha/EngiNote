import AVFoundation
import UIKit

/// A stretch of the recording that is kept, in the recording's own time (seconds).
fileprivate struct EditPiece: Equatable {
    var start: Double
    var end: Double
    var length: Double { end - start }
}

/// Which kept piece the edited movie's time `t` falls in (the last one, at the very end).
fileprivate func pieceIndex(_ pieces: [EditPiece], at t: Double) -> Int {
    var end = 0.0
    for (i, piece) in pieces.enumerated() {
        end += piece.length
        if t < end { return i }
    }
    return max(pieces.count - 1, 0)
}

/// Where piece `index` begins in the edited movie.
fileprivate func pieceStart(_ pieces: [EditPiece], _ index: Int) -> Double {
    pieces.prefix(index).reduce(0) { $0 + $1.length }
}

fileprivate struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A simple editor for one recording: trim it, split it, cut parts out, undo and redo; then it is
/// saved as a new recording next to the original, which is never touched.
///
/// The edit is only a list of the stretches to keep (`pieces`); the preview plays that list live as
/// a composition, and Save writes the same composition out as a new movie (re-encoded, so every cut
/// is exact to the frame). Undo and redo keep every earlier list.
///
/// Like the recorder, this can only be proven on the iPad itself.
final class VideoEditor: UIViewController {
    /// Called on the main thread once the edited recording is saved (the list of recordings has changed).
    var onSaved: (() -> Void)?

    private let file: URL
    private let asset: AVURLAsset
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    private var videoRange = CMTimeRange.zero
    private var audioRange = CMTimeRange.zero
    private var transform = CGAffineTransform.identity
    private var duration = 0.0

    private var pieces: [EditPiece] = []
    private var original: [EditPiece] = []
    private var undoStack: [[EditPiece]] = []
    private var redoStack: [[EditPiece]] = []
    private var time = 0.0 // the playhead, in the edited movie
    private var total: Double { pieces.reduce(0) { $0 + $1.length } }
    private var playing = false
    private var laidOut = false

    private let player = AVPlayer()
    private var tickToken: Any?
    private var endToken: NSObjectProtocol?
    private var generator: AVAssetImageGenerator?
    private var exporting: AVAssetExportSession?
    private var ticker: Timer?

    private let playerView = PlayerView()
    private let timeline = EditTimeline()
    private let timeLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private var cancelButton = UIButton(type: .system)
    private var saveButton = UIButton(type: .system)
    private var undoButton = UIButton(type: .system)
    private var redoButton = UIButton(type: .system)
    private var splitButton = UIButton(type: .system)
    private var deleteButton = UIButton(type: .system)
    private let shield = UIView() // over everything while saving
    private let bar = UIProgressView(progressViewStyle: .default)

    init(file: URL) {
        self.file = file
        self.asset = AVURLAsset(url: file)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError("not made from a storyboard") }

    deinit {
        if let token = tickToken { player.removeTimeObserver(token) }
        if let token = endToken { NotificationCenter.default.removeObserver(token) }
        ticker?.invalidate()
    }

    override var prefersStatusBarHidden: Bool { true }

    // MARK: Screen

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        try? AVAudioSession.sharedInstance().setCategory(.playback) // sound even with the silent switch on
        try? AVAudioSession.sharedInstance().setActive(true)

        cancelButton = textButton("Cancel", bold: false, #selector(cancelTapped))
        saveButton = textButton("Save", bold: true, #selector(save))
        let title = UILabel()
        title.text = "Edit recording"
        title.textColor = .white
        title.font = .boldSystemFont(ofSize: 17)

        playerView.playerLayer.player = player
        playerView.playerLayer.videoGravity = .resizeAspect
        player.actionAtItemEnd = .pause

        timeLabel.textColor = .white
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        timeLabel.text = "0:00.0 / 0:00.0"
        playButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)), for: .normal)
        playButton.tintColor = .white
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        let transport = UIStackView(arrangedSubviews: [playButton, timeLabel])
        transport.spacing = 16
        transport.alignment = .center

        undoButton = tool("Undo", "arrow.uturn.backward", .white, #selector(undo))
        redoButton = tool("Redo", "arrow.uturn.forward", .white, #selector(redo))
        splitButton = tool("Split", "scissors", .white, #selector(split))
        deleteButton = tool("Delete", "trash", .systemRed, #selector(remove))
        let tools = UIStackView(arrangedSubviews: [undoButton, redoButton, splitButton, deleteButton])
        tools.distribution = .fillEqually

        for item in [cancelButton, saveButton, title, playerView, transport, timeline, tools] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            cancelButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            saveButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            saveButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            playerView.topAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: 8),
            playerView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: transport.topAnchor, constant: -8),
            transport.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            transport.heightAnchor.constraint(equalToConstant: 44),
            transport.bottomAnchor.constraint(equalTo: timeline.topAnchor, constant: -8),
            timeline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            timeline.heightAnchor.constraint(equalToConstant: 100),
            timeline.bottomAnchor.constraint(equalTo: tools.topAnchor, constant: -8),
            tools.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            tools.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            tools.heightAnchor.constraint(equalToConstant: 60),
            tools.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
        ])
        buildShield()

        timeline.onTouch = { [weak self] in self?.setPlaying(false) }
        timeline.onMove = { [weak self] t in
            guard let self = self else { return }
            self.time = t
            self.seek()
            self.refresh()
        }
        tickToken = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self = self, self.playing, t.isNumeric else { return }
            self.time = min(max(t.seconds, 0), self.total)
            self.timeline.time = self.time
            self.refresh()
        }
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.time = self.total
            self.timeline.time = self.time
            self.setPlaying(false)
            self.refresh()
        }

        for button in [undoButton, redoButton, splitButton, deleteButton, saveButton, playButton] { enable(button, false) }
        Task { await load() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !pieces.isEmpty, !laidOut, timeline.bounds.width > 0 {
            laidOut = true
            zoomToFit(reset: true)
        }
    }

    private func textButton(_ text: String, bold: Bool, _ action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = text
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = bold ? .boldSystemFont(ofSize: 17) : .systemFont(ofSize: 17)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func tool(_ text: String, _ symbol: String, _ color: UIColor, _ action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = text
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePlacement = .top
        configuration.imagePadding = 4
        configuration.baseForegroundColor = color
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func enable(_ button: UIButton, _ on: Bool) {
        button.isEnabled = on
        button.alpha = on ? 1 : 0.35
    }

    private func buildShield() {
        shield.backgroundColor = UIColor(white: 0, alpha: 0.8)
        shield.isHidden = true
        shield.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shield)
        let label = UILabel()
        label.text = "Saving the edited recording…"
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .medium)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = "Stop"
        let stop = UIButton(configuration: configuration)
        stop.addTarget(self, action: #selector(stopSaving), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, bar, stop])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        shield.addSubview(stack)
        NSLayoutConstraint.activate([
            shield.topAnchor.constraint(equalTo: view.topAnchor),
            shield.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            shield.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shield.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: shield.centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 320),
        ])
    }

    // MARK: Opening the recording

    private func load() async {
        do {
            let length = try await asset.load(.duration).seconds
            guard length.isFinite, length > 0.3 else { throw Failure(message: "it is too short") }
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure(message: "it has no picture") }
            transform = try await video.load(.preferredTransform)
            let size = try await video.load(.naturalSize).applying(transform)
            timeline.aspect = abs(size.width) / max(abs(size.height), 1)
            videoRange = try await video.load(.timeRange)
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                audioTrack = sound
                audioRange = try await sound.load(.timeRange)
            }
            videoTrack = video
            duration = length
            pieces = [EditPiece(start: 0, end: length)]
            original = pieces
            timeline.pieces = pieces
            timeline.sourceDuration = length
            enable(playButton, true)
            rebuild()
            makeThumbnails()
            if timeline.bounds.width > 0 {
                laidOut = true
                zoomToFit(reset: true)
            }
            refresh()
        } catch {
            problem("This recording could not be opened (\(error.localizedDescription)).", leave: true)
        }
    }

    private func makeThumbnails() {
        let count = min(200, max(30, Int(duration / 5)))
        let step = duration / Double(count)
        timeline.thumbs = Array(repeating: nil, count: count)
        let times = (0..<count).map { NSValue(time: CMTime(seconds: step * (Double($0) + 0.5), preferredTimescale: 600)) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = .positiveInfinity // the nearest whole picture: much quicker
        generator.requestedTimeToleranceAfter = .positiveInfinity
        self.generator = generator
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, result, _ in
            guard result == .succeeded, let image = image else { return }
            let index = min(count - 1, max(0, Int(requested.seconds / step)))
            DispatchQueue.main.async {
                guard let self = self, self.timeline.thumbs.indices.contains(index) else { return }
                self.timeline.thumbs[index] = UIImage(cgImage: image)
                self.timeline.setNeedsDisplay()
            }
        }
    }

    // MARK: The edit

    /// The kept pieces, one after the other, as a movie.
    private func makeComposition() -> AVMutableComposition {
        let composition = AVMutableComposition()
        let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        picture?.preferredTransform = transform
        let sound = audioTrack == nil ? nil : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var at = CMTime.zero
        for piece in pieces {
            let range = CMTimeRange(start: CMTime(seconds: piece.start, preferredTimescale: 600), duration: CMTime(seconds: piece.length, preferredTimescale: 600))
            // A track may end a hair before the file does: ask only for what it has.
            if let video = videoTrack {
                try? picture?.insertTimeRange(CMTimeRangeGetIntersection(range, otherRange: videoRange), of: video, at: at)
            }
            if let heard = audioTrack {
                try? sound?.insertTimeRange(CMTimeRangeGetIntersection(range, otherRange: audioRange), of: heard, at: at)
            }
            at = CMTimeAdd(at, range.duration)
        }
        return composition
    }

    private func rebuild() {
        player.replaceCurrentItem(with: AVPlayerItem(asset: makeComposition()))
        seek()
    }

    private func seek() {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func commit(_ next: [EditPiece]) {
        undoStack.append(pieces)
        redoStack = []
        pieces = next
        changed()
    }

    private func changed() {
        time = min(time, total)
        timeline.pieces = pieces
        timeline.time = time
        setPlaying(false)
        zoomToFit(reset: false)
        rebuild()
        refresh()
    }

    @objc private func undo() {
        guard let before = undoStack.popLast() else { return }
        redoStack.append(pieces)
        pieces = before
        changed()
    }

    @objc private func redo() {
        guard let after = redoStack.popLast() else { return }
        undoStack.append(pieces)
        pieces = after
        changed()
    }

    /// Cut the piece under the playhead in two, there.
    @objc private func split() {
        guard !pieces.isEmpty else { return }
        let i = pieceIndex(pieces, at: time)
        let piece = pieces[i]
        let local = time - pieceStart(pieces, i)
        guard local > 0.1, piece.length - local > 0.1 else { return }
        let cut = ((piece.start + local) * 60).rounded() / 60 // on a frame
        var next = pieces
        next[i] = EditPiece(start: piece.start, end: cut)
        next.insert(EditPiece(start: cut, end: piece.end), at: i + 1)
        commit(next)
    }

    /// Take the piece under the playhead out; what is after it closes up to what is before.
    @objc private func remove() {
        guard pieces.count > 1 else { return }
        var next = pieces
        next.remove(at: pieceIndex(pieces, at: time))
        commit(next)
    }

    /// The whole edited movie fits across the timeline at the furthest zoom out. (`reset`: start there.)
    private func zoomToFit(reset: Bool) {
        let fit = max(0.05, timeline.bounds.width * 0.9 / CGFloat(max(total, 0.1)))
        timeline.maxPPS = max(400, fit)
        timeline.minPPS = fit
        timeline.pps = reset ? fit : min(max(timeline.pps, fit), timeline.maxPPS)
    }

    private func refresh() {
        guard !pieces.isEmpty else { return }
        let i = pieceIndex(pieces, at: time)
        let local = time - pieceStart(pieces, i)
        enable(splitButton, local > 0.1 && pieces[i].length - local > 0.1)
        enable(deleteButton, pieces.count > 1)
        enable(undoButton, !undoStack.isEmpty)
        enable(redoButton, !redoStack.isEmpty)
        enable(saveButton, pieces != original)
        timeLabel.text = "\(stamp(time)) / \(stamp(total))"
    }

    private func stamp(_ t: Double) -> String {
        let whole = Int(t)
        let tenth = Int((t - Double(whole)) * 10)
        let (h, m, s) = (whole / 3600, whole % 3600 / 60, whole % 60)
        return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, s, tenth) : String(format: "%d:%02d.%d", m, s, tenth)
    }

    // MARK: Playing

    @objc private func playTapped() { setPlaying(!playing) }

    private func setPlaying(_ on: Bool) {
        let on = on && !pieces.isEmpty
        if on, time >= total - 0.05 {
            time = 0
            timeline.time = 0
            seek()
        }
        playing = on
        on ? player.play() : player.pause()
        let symbol = on ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)), for: .normal)
    }

    // MARK: Leaving and saving

    @objc private func cancelTapped() {
        setPlaying(false)
        guard pieces != original else {
            dismiss(animated: true)
            return
        }
        let ask = UIAlertController(title: "Discard your edits?", message: "Nothing has been saved yet.", preferredStyle: .alert)
        ask.addAction(UIAlertAction(title: "Keep editing", style: .cancel))
        ask.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in self?.dismiss(animated: true) })
        present(ask, animated: true)
    }

    /// A name for the edited recording that is free: "Thermodynamics (edited) 2026-10-11 14.03.22.mov".
    private func freeURL() -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        var name = base
        var stampText = ""
        if let found = base.range(of: #" \d{4}-\d\d-\d\d \d\d\.\d\d\.\d\d$"#, options: .regularExpression) {
            name = String(base[..<found.lowerBound])
            stampText = String(base[found])
        }
        let folder = file.deletingLastPathComponent()
        var n = 1
        while true {
            let label = n == 1 ? "(edited)" : "(edited \(n))"
            let url = folder.appendingPathComponent("\(name) \(label)\(stampText).mov")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    @objc private func save() {
        guard !pieces.isEmpty, pieces != original else { return }
        setPlaying(false)
        let target = freeURL()
        guard let session = AVAssetExportSession(asset: makeComposition(), presetName: AVAssetExportPresetHighestQuality) else {
            problem("This iPad cannot save this recording.", leave: false)
            return
        }
        session.outputURL = target
        session.outputFileType = .mov
        exporting = session
        bar.progress = 0
        shield.isHidden = false
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.bar.progress = self?.exporting?.progress ?? 0
        }
        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async { self?.exported(session, to: target) }
        }
    }

    @objc private func stopSaving() { exporting?.cancelExport() }

    private func exported(_ session: AVAssetExportSession, to target: URL) {
        ticker?.invalidate()
        exporting = nil
        shield.isHidden = true
        switch session.status {
        case .completed:
            onSaved?()
            dismiss(animated: true)
        case .cancelled:
            try? FileManager.default.removeItem(at: target)
        default:
            try? FileManager.default.removeItem(at: target)
            problem("The edited recording could not be saved (\(session.error?.localizedDescription ?? "unknown reason")).", leave: false)
        }
    }

    private func problem(_ message: String, leave: Bool) {
        let alert = UIAlertController(title: "Edit recording", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            if leave { self?.dismiss(animated: true) }
        })
        present(alert, animated: true)
    }
}

/// A view whose layer plays video.
private final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The strip of the kept pieces, with the playhead fixed in the middle: drag along it to move through
/// the movie, pinch to zoom, tap to jump. The piece under the playhead (the one Split and Delete
/// act on) has a yellow outline.
private final class EditTimeline: UIView {
    fileprivate var pieces: [EditPiece] = [] { didSet { setNeedsDisplay() } }
    var time = 0.0 { didSet { setNeedsDisplay() } }
    var pps: CGFloat = 50 { didSet { setNeedsDisplay() } } // points to a second
    var minPPS: CGFloat = 1
    var maxPPS: CGFloat = 400
    var thumbs: [UIImage?] = [] // evenly spread over the whole original recording
    var sourceDuration = 1.0
    var aspect: CGFloat = 16 / 9
    /// A finger came down: stop playing.
    var onTouch: (() -> Void)?
    /// The playhead was moved by the user, to this time in the edited movie.
    var onMove: ((Double) -> Void)?
    private var coast: Timer?

    private var total: Double { pieces.reduce(0) { $0 + $1.length } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched)))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("not made from a storyboard") }

    private func move(to t: Double) {
        time = min(max(t, 0), total)
        onMove?(time)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            coast?.invalidate()
            onTouch?()
        case .changed:
            let dx = pan.translation(in: self).x
            pan.setTranslation(.zero, in: self)
            move(to: time - Double(dx / pps))
        case .ended:
            var speed = pan.velocity(in: self).x // points a second; it slows down by itself
            coast = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self = self, abs(speed) > 15 else {
                    timer.invalidate()
                    return
                }
                self.move(to: self.time - Double(speed / 60 / self.pps))
                speed *= 0.95
            }
        default:
            break
        }
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        if pinch.state == .began {
            coast?.invalidate()
            onTouch?()
        }
        pps = min(max(pps * pinch.scale, minPPS), maxPPS)
        pinch.scale = 1
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        coast?.invalidate()
        onTouch?()
        move(to: time + Double((tap.location(in: self).x - bounds.width / 2) / pps))
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let mid = bounds.width / 2
        let top: CGFloat = 14
        let height = bounds.height - 28
        let selected = pieceIndex(pieces, at: time)
        var begin = 0.0
        for (i, piece) in pieces.enumerated() {
            let x0 = mid + CGFloat(begin - time) * pps
            let width = CGFloat(piece.length) * pps
            begin += piece.length
            if x0 + width < 0 || x0 > bounds.width { continue }
            let band = CGRect(x: x0 + 1, y: top, width: max(width - 2, 1), height: height)
            let shape = UIBezierPath(roundedRect: band, cornerRadius: 6)
            context.saveGState()
            shape.addClip()
            UIColor(white: 0.2, alpha: 1).setFill()
            context.fill(band)
            // The pictures, one tile after another, only across the part that is on screen.
            let tile = max(8, height * aspect)
            var x = x0 >= 0 ? x0 : x0 + floor(-x0 / tile) * tile
            while x < min(x0 + width, bounds.width), !thumbs.isEmpty {
                let at = piece.start + Double((x + tile / 2 - x0) / pps)
                let index = min(thumbs.count - 1, max(0, Int(min(max(at, piece.start), piece.end) / sourceDuration * Double(thumbs.count))))
                thumbs[index]?.draw(in: CGRect(x: x, y: top, width: tile, height: height))
                x += tile
            }
            context.restoreGState()
            if i == selected {
                UIColor.systemYellow.setStroke()
                shape.lineWidth = 3
                shape.stroke()
            }
        }
        // The playhead.
        UIColor.white.setFill()
        context.fill(CGRect(x: mid - 1, y: 0, width: 2, height: bounds.height))
        UIBezierPath(ovalIn: CGRect(x: mid - 5, y: 0, width: 10, height: 10)).fill()
    }
}
