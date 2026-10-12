import AVFoundation
import UIKit

/// A stretch of one recording that is kept (`clip` says which, as a place in the editor's list of
/// recordings), in that recording's own time (seconds).
fileprivate struct EditPiece: Equatable {
    var clip: Int
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

/// A recording the edit takes pieces from, opened: its tracks and how it is shown.
fileprivate final class Clip {
    let url: URL
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: AVAssetTrack?
    let videoRange: CMTimeRange
    let audioRange: CMTimeRange
    let transform: CGAffineTransform
    let natural: CGSize
    let duration: Double
    /// Pictures evenly spread over the whole recording, for the timeline; filled in as they are made.
    var thumbs: [UIImage?] = []
    var generator: AVAssetImageGenerator?

    private init(url: URL, asset: AVURLAsset, video: AVAssetTrack, audio: AVAssetTrack?, videoRange: CMTimeRange, audioRange: CMTimeRange, transform: CGAffineTransform, natural: CGSize, duration: Double) {
        self.url = url
        self.asset = asset
        self.video = video
        self.audio = audio
        self.videoRange = videoRange
        self.audioRange = audioRange
        self.transform = transform
        self.natural = natural
        self.duration = duration
    }

    static func open(_ url: URL) async throws -> Clip {
        let asset = AVURLAsset(url: url)
        let length = try await asset.load(.duration).seconds
        guard length.isFinite, length > 0.3 else { throw Failure(message: "it is too short") }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure(message: "it has no picture") }
        let transform = try await video.load(.preferredTransform)
        let natural = try await video.load(.naturalSize)
        let videoRange = try await video.load(.timeRange)
        var audio: AVAssetTrack?
        var audioRange = CMTimeRange.zero
        if let sound = try await asset.loadTracks(withMediaType: .audio).first {
            audio = sound
            audioRange = try await sound.load(.timeRange)
        }
        return Clip(url: url, asset: asset, video: video, audio: audio, videoRange: videoRange, audioRange: audioRange, transform: transform, natural: natural, duration: length)
    }

    /// The picture's size as it is watched (a recording made on its side is turned upright).
    var shown: CGSize {
        let size = natural.applying(transform)
        return CGSize(width: max(abs(size.width), 2), height: max(abs(size.height), 2))
    }

    /// How to lay this recording's picture into a movie `render` big: turned upright, as large as fits, in the middle.
    func fit(into render: CGSize) -> CGAffineTransform {
        let box = CGRect(origin: .zero, size: natural).applying(transform)
        let scale = min(render.width / shown.width, render.height / shown.height)
        return transform
            .concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (render.width - shown.width * scale) / 2, y: (render.height - shown.height * scale) / 2))
    }
}

/// Lists the recordings in the app's folder, to choose one to add to the edit.
private final class RecordingPicker: UITableViewController {
    private let files: [(url: URL, detail: String)]
    private let chosen: (URL) -> Void

    init(folder: URL, skipping: Set<String>, chosen: @escaping (URL) -> Void) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        files = found
            .filter { $0.pathExtension.lowercased() == "mov" && !skipping.contains($0.lastPathComponent) }
            .map { url -> (url: URL, when: Date, size: Int) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
            }
            .sorted { $0.when > $1.when }
            .map { ($0.url, "\(dates.string(from: $0.when)) · \(max(1, $0.size / 1_000_000)) MB") }
        self.chosen = chosen
        super.init(style: .insetGrouped)
        title = "Add a recording"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    }

    required init?(coder: NSCoder) { fatalError("not made from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if files.isEmpty {
            let none = UILabel()
            none.text = "There is no other recording to add."
            none.textColor = .secondaryLabel
            none.textAlignment = .center
            tableView.backgroundView = none
        }
    }

    @objc private func cancel() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { files.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = files[indexPath.row].url.deletingPathExtension().lastPathComponent
        content.secondaryText = files[indexPath.row].detail
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let url = files[indexPath.row].url
        dismiss(animated: true) { [chosen] in chosen(url) }
    }
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
    private let busy: String? // the recording being made right now: not to be added
    private var clips: [Clip] = [] // the recording being edited, then any that were added; only ever grows, so pieces can name them
    private var renderSize = CGSize(width: 1920, height: 1080) // the picture of the edited movie: the first recording's

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
    private var addButton = UIButton(type: .system)
    private let shield = UIView() // over everything while saving
    private let bar = UIProgressView(progressViewStyle: .default)

    /// `busy`: the name of the recording being made right now, if any.
    init(file: URL, busy: String? = nil) {
        self.file = file
        self.busy = busy
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
        addButton = tool("Add video", "plus.rectangle.on.rectangle", .white, #selector(addTapped))
        let tools = UIStackView(arrangedSubviews: [undoButton, redoButton, splitButton, deleteButton, addButton])
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

        for button in [undoButton, redoButton, splitButton, deleteButton, addButton, saveButton, playButton] { enable(button, false) }
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
            let first = try await Clip.open(file)
            clips = [first]
            renderSize = CGSize(width: ceil(first.shown.width / 2) * 2, height: ceil(first.shown.height / 2) * 2) // encoders want even numbers
            pieces = [EditPiece(clip: 0, start: 0, end: first.duration)]
            original = pieces
            timeline.clips = clips
            timeline.pieces = pieces
            enable(playButton, true)
            rebuild()
            makeThumbnails(for: first)
            if timeline.bounds.width > 0 {
                laidOut = true
                zoomToFit(reset: true)
            }
            refresh()
        } catch {
            problem("This recording could not be opened (\(error.localizedDescription)).", leave: true)
        }
    }

    private func makeThumbnails(for clip: Clip) {
        let count = min(200, max(30, Int(clip.duration / 5)))
        let step = clip.duration / Double(count)
        clip.thumbs = Array(repeating: nil, count: count)
        let times = (0..<count).map { NSValue(time: CMTime(seconds: step * (Double($0) + 0.5), preferredTimescale: 600)) }
        let generator = AVAssetImageGenerator(asset: clip.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = .positiveInfinity // the nearest whole picture: much quicker
        generator.requestedTimeToleranceAfter = .positiveInfinity
        clip.generator = generator
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, result, _ in
            guard result == .succeeded, let image = image else { return }
            let index = min(count - 1, max(0, Int(requested.seconds / step)))
            DispatchQueue.main.async {
                guard clip.thumbs.indices.contains(index) else { return }
                clip.thumbs[index] = UIImage(cgImage: image)
                self?.timeline.setNeedsDisplay()
            }
        }
    }

    // MARK: The edit

    /// The kept pieces, one after the other, as a movie. With recordings added, each piece is laid
    /// into the same picture size (`video`), whatever size it was made at; with just the one, the
    /// movie is simply turned as that recording is and there is no `video`.
    private func makeComposition() -> (movie: AVMutableComposition, video: AVMutableVideoComposition?) {
        let composition = AVMutableComposition()
        let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let sound = clips.contains { $0.audio != nil } ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let used = Set(pieces.map { $0.clip })
        let several = used.count > 1
        if !several, let only = used.first, clips.indices.contains(only) { picture?.preferredTransform = clips[only].transform }
        var at = CMTime.zero
        var steps: [(range: CMTimeRange, clip: Clip)] = []
        for piece in pieces where clips.indices.contains(piece.clip) {
            let clip = clips[piece.clip]
            let range = CMTimeRange(start: CMTime(seconds: piece.start, preferredTimescale: 600), duration: CMTime(seconds: piece.length, preferredTimescale: 600))
            // A track may end a hair before the file does: ask only for what it has.
            try? picture?.insertTimeRange(CMTimeRangeGetIntersection(range, otherRange: clip.videoRange), of: clip.video, at: at)
            if let heard = clip.audio {
                try? sound?.insertTimeRange(CMTimeRangeGetIntersection(range, otherRange: clip.audioRange), of: heard, at: at)
            }
            steps.append((CMTimeRange(start: at, duration: range.duration), clip))
            at = CMTimeAdd(at, range.duration)
        }
        guard several, let picture = picture else { return (composition, nil) }
        let video = AVMutableVideoComposition()
        video.renderSize = renderSize
        video.frameDuration = CMTime(value: 1, timescale: 60)
        video.instructions = steps.map { step -> AVMutableVideoCompositionInstruction in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = step.range
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: picture)
            layer.setTransform(step.clip.fit(into: renderSize), at: .zero)
            instruction.layerInstructions = [layer]
            return instruction
        }
        return (composition, video)
    }

    private func rebuild() {
        let made = makeComposition()
        let item = AVPlayerItem(asset: made.movie)
        item.videoComposition = made.video
        player.replaceCurrentItem(with: item)
        seek()
    }

    // MARK: Adding a recording

    @objc private func addTapped() {
        setPlaying(false)
        let picker = RecordingPicker(folder: file.deletingLastPathComponent(), skipping: [file.lastPathComponent, busy ?? ""]) { [weak self] url in self?.add(url) }
        let sheet = UINavigationController(rootViewController: picker)
        sheet.modalPresentationStyle = .formSheet
        present(sheet, animated: true)
    }

    /// Put the whole of recording `url` at the end of the edit, as one more piece.
    private func add(_ url: URL) {
        Task {
            do {
                let clip = try await Clip.open(url)
                clips.append(clip)
                timeline.clips = clips
                makeThumbnails(for: clip)
                var next = pieces
                next.append(EditPiece(clip: clips.count - 1, start: 0, end: clip.duration))
                time = total // the playhead goes to where the new one begins
                commit(next)
            } catch {
                problem("That recording could not be added (\(error.localizedDescription)).", leave: false)
            }
        }
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
        next[i] = EditPiece(clip: piece.clip, start: piece.start, end: cut)
        next.insert(EditPiece(clip: piece.clip, start: cut, end: piece.end), at: i + 1)
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
        enable(addButton, true)
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
        let made = makeComposition()
        guard let session = AVAssetExportSession(asset: made.movie, presetName: AVAssetExportPresetHighestQuality) else {
            problem("This iPad cannot save this recording.", leave: false)
            return
        }
        session.videoComposition = made.video
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
    fileprivate var clips: [Clip] = [] // what the pieces are cut from, with their pictures
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
            if clips.indices.contains(piece.clip) {
                let clip = clips[piece.clip]
                let tile = max(8, height * clip.shown.width / clip.shown.height)
                var x = x0 >= 0 ? x0 : x0 + floor(-x0 / tile) * tile
                while x < min(x0 + width, bounds.width), !clip.thumbs.isEmpty {
                    let at = piece.start + Double((x + tile / 2 - x0) / pps)
                    let index = min(clip.thumbs.count - 1, max(0, Int(min(max(at, piece.start), piece.end) / clip.duration * Double(clip.thumbs.count))))
                    clip.thumbs[index]?.draw(in: CGRect(x: x, y: top, width: tile, height: height))
                    x += tile
                }
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
