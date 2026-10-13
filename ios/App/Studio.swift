import AVFoundation
import UIKit

/// Studio's screen: what to do to a recording, and a button that does it. The work itself is in StudioRender.swift.
///
/// Everything is optional and decided here, after the recording is made, so nothing has to be chosen before the
/// lecture starts: the recorder only keeps the pen's path (a few numbers a second), which is what auto-zoom needs.
/// The recording itself is never changed: the finished video is a new recording beside it.
final class StudioViewController: UIViewController {
    private let movie: URL
    private let sidecar: Sidecar?
    private let intro = Bundle.main.url(forResource: "studio-intro", withExtension: "mp4")
    private let outro = Bundle.main.url(forResource: "studio-outro", withExtension: "mp4")
    var onSaved: (() -> Void)?

    private var length = 0.0 // the recording's, in seconds
    private var task: Task<Void, Never>?
    private var cancel = StudioCancel()

    private let zoomSwitch = UISwitch(), polishSwitch = UISwitch(), introSwitch = UISwitch(), outroSwitch = UISwitch(), shortSwitch = UISwitch()
    private let startSlider = UISlider()
    private let startLabel = UILabel()
    private let lengthPicker = UISegmentedControl(items: ["30 s", "45 s", "60 s", "90 s"])
    private let shortBox = UIStackView()
    private let makeButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let status = UILabel()
    private var optionViews: [UIView] = []

    private static let lengths = [30.0, 45.0, 60.0, 90.0]
    private let defaults = UserDefaults.standard

    init(movie: URL) {
        self.movie = movie
        sidecar = Sidecar.load(for: movie)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError("not made from a storyboard") }

    // MARK: Screen

    private func remembered(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: "studio." + key) as? Bool ?? fallback
    }

    /// One choice: a switch with what it does under its name.
    private func row(_ title: String, _ detail: String, _ toggle: UISwitch, key: String, fallback: Bool, available: Bool = true) -> UIView {
        let name = UILabel()
        name.text = title
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        name.textColor = available ? .white : .gray
        let what = UILabel()
        what.text = detail
        what.font = .systemFont(ofSize: 13)
        what.textColor = .lightGray
        what.numberOfLines = 0
        let words = UIStackView(arrangedSubviews: [name, what])
        words.axis = .vertical
        words.spacing = 3
        toggle.isOn = available && remembered(key, fallback)
        toggle.isEnabled = available
        toggle.onTintColor = UIColor(red: 0.875, green: 1, blue: 0.447, alpha: 1) // the site's lime
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let toggle = toggle else { return }
            self?.defaults.set(toggle.isOn, forKey: "studio." + key)
            self?.refreshShortBox()
        }, for: .valueChanged)
        let line = UIStackView(arrangedSubviews: [words, toggle])
        line.spacing = 16
        line.alignment = .center
        let card = UIView()
        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 12
        line.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: card.topAnchor, constant: 14), line.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            line.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), line.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        optionViews.append(card)
        return card
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let heading = UILabel()
        heading.text = "Studio"
        heading.font = .systemFont(ofSize: 28, weight: .heavy)
        heading.textColor = .white
        let name = UILabel()
        name.text = StudioRender.title(of: movie)
        name.font = .systemFont(ofSize: 15)
        name.textColor = .lightGray
        closeButton.setTitle("Close", for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let hasPen = (sidecar?.penPath().contains { $0.down }) ?? false
        let zoom = row("Auto-zoom on the writing", hasPen
            ? "The picture eases in on whatever you are writing, and back out when you stop. The camera bubble stays where it is."
            : (sidecar == nil ? "Needs a recording made straight in EngiNote: this one was trimmed or edited, or made before Studio." : "The pen was not used in this recording."),
            zoomSwitch, key: "zoom", fallback: true, available: hasPen)
        let polish = row("Polish the voice", "Takes out rumble, evens out loud and quiet words, and sets the loudness to what YouTube plays at.", polishSwitch, key: "polish", fallback: true)
        let start = row("Intro", intro == nil ? "Not in this build." : "The EngiKode intro video, before the recording.", introSwitch, key: "intro", fallback: true, available: intro != nil)
        let end = row("Outro", outro == nil ? "Not in this build." : "The EngiKode outro, after the recording.", outroSwitch, key: "outro", fallback: true, available: outro != nil)
        let short = row("Also make a vertical short", "A 9:16 video for Shorts and Reels: the writing, zoomed, with your face and the channel below.", shortSwitch, key: "short", fallback: false)

        // The short's start and length.
        startSlider.minimumTrackTintColor = UIColor(red: 0.875, green: 1, blue: 0.447, alpha: 1)
        startSlider.addTarget(self, action: #selector(startMoved), for: .valueChanged)
        startLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        startLabel.textColor = .white
        lengthPicker.selectedSegmentIndex = min(StudioViewController.lengths.count - 1, max(0, defaults.integer(forKey: "studio.shortLength")))
        lengthPicker.addTarget(self, action: #selector(startMoved), for: .valueChanged)
        let startRow = UIStackView(arrangedSubviews: [UILabel.plain("Starts at"), startSlider, startLabel])
        startRow.spacing = 12
        startRow.alignment = .center
        let lengthRow = UIStackView(arrangedSubviews: [UILabel.plain("Length"), lengthPicker])
        lengthRow.spacing = 12
        lengthRow.alignment = .center
        shortBox.axis = .vertical
        shortBox.spacing = 12
        shortBox.isLayoutMarginsRelativeArrangement = true
        shortBox.layoutMargins = UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        shortBox.addArrangedSubview(startRow)
        shortBox.addArrangedSubview(lengthRow)

        makeButton.setTitle("Make the video", for: .normal)
        makeButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .heavy)
        makeButton.setTitleColor(UIColor(red: 0.09, green: 0.15, blue: 0.125, alpha: 1), for: .normal)
        makeButton.backgroundColor = UIColor(red: 0.875, green: 1, blue: 0.447, alpha: 1)
        makeButton.layer.cornerRadius = 12
        makeButton.heightAnchor.constraint(equalToConstant: 54).isActive = true
        makeButton.addTarget(self, action: #selector(makeTapped), for: .touchUpInside)

        progress.progressTintColor = UIColor(red: 0.875, green: 1, blue: 0.447, alpha: 1)
        progress.isHidden = true
        status.font = .systemFont(ofSize: 14)
        status.textColor = .lightGray
        status.numberOfLines = 0
        status.textAlignment = .center

        // What the recorder counted about the sound, when it did (Recorder.swift, take).
        let sound = UILabel()
        sound.text = sidecar?.soundReport
        sound.font = .systemFont(ofSize: 13)
        sound.textColor = .lightGray
        sound.numberOfLines = 0
        sound.isHidden = sound.text == nil

        let stack = UIStackView(arrangedSubviews: [name, sound, zoom, polish, start, end, short, shortBox, makeButton, progress, status])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(sound.isHidden ? 18 : 6, after: name)
        stack.setCustomSpacing(18, after: sound)
        stack.setCustomSpacing(20, after: shortBox)

        let scroll = UIScrollView()
        for item in [heading, closeButton, scroll, stack] as [UIView] { item.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(heading)
        view.addSubview(closeButton)
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: guide.topAnchor, constant: 20), heading.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            closeButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor), closeButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -30),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
        // Its length decides how far the short's start can go.
        Task { [weak self] in
            guard let self = self else { return }
            let seconds = (try? await AVURLAsset(url: self.movie).load(.duration).seconds) ?? 0
            await MainActor.run {
                self.length = seconds
                self.startSlider.maximumValue = Float(max(0, seconds - 10))
                self.startSlider.value = 0
                self.startMoved()
            }
        }
        refreshShortBox()
    }

    override var prefersStatusBarHidden: Bool { true }

    private func refreshShortBox() {
        shortBox.isHidden = !shortSwitch.isOn
    }

    private func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @objc private func startMoved() {
        startLabel.text = time(Double(startSlider.value))
        defaults.set(lengthPicker.selectedSegmentIndex, forKey: "studio.shortLength")
    }

    // MARK: Doing it

    private func setBusy(_ busy: Bool) {
        optionViews.forEach { $0.alpha = busy ? 0.4 : 1; $0.isUserInteractionEnabled = !busy }
        shortBox.alpha = busy ? 0.4 : 1
        shortBox.isUserInteractionEnabled = !busy
        progress.isHidden = !busy
        makeButton.setTitle(busy ? "Stop" : "Make the video", for: .normal)
        UIApplication.shared.isIdleTimerDisabled = busy // the screen must not lock part-way through
        closeButton.isEnabled = !busy
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func makeTapped() {
        if task != nil { // "Stop"
            cancel.set()
            status.text = "Stopping..."
            return
        }
        var options = StudioOptions()
        options.autoZoom = zoomSwitch.isOn
        options.polish = polishSwitch.isOn
        options.intro = introSwitch.isOn && intro != nil
        options.outro = outroSwitch.isOn && outro != nil
        options.short = shortSwitch.isOn
        options.shortStart = Double(startSlider.value)
        options.shortLength = StudioViewController.lengths[lengthPicker.selectedSegmentIndex]
        guard options.autoZoom || options.polish || options.intro || options.outro || options.short else {
            status.text = "Choose at least one thing to do."
            return
        }
        cancel = StudioCancel()
        setBusy(true)
        progress.progress = 0
        status.text = "Starting..."
        let movie = movie, intro = intro, outro = outro, cancel = cancel
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let folder = try Recorder.folder()
                let made = try await StudioRender.run(movie: movie, options: options, intro: intro, outro: outro, folder: folder, cancel: cancel) { fraction, what in
                    DispatchQueue.main.async {
                        self?.progress.setProgress(Float(fraction), animated: true)
                        self?.status.text = "\(what)... \(Int(fraction * 100))%. Keep EngiNote open until it is done."
                    }
                }
                await MainActor.run { self?.finished(made) }
            } catch {
                await MainActor.run { self?.failed(error) }
            }
        }
    }

    private func finished(_ made: StudioRender.Made) {
        task = nil
        setBusy(false)
        onSaved?()
        let names = made.files.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: "\n")
        let notes = made.notes.isEmpty ? "" : "\n\n" + made.notes.joined(separator: "\n")
        status.text = "Done. It is in your recordings."
        let done = UIAlertController(title: "Your video is ready", message: names + notes, preferredStyle: .alert)
        if !made.files.isEmpty {
            done.addAction(UIAlertAction(title: "Share", style: .default) { [weak self] _ in
                guard let self = self else { return }
                let sheet = UIActivityViewController(activityItems: made.files, applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = self.makeButton
                self.present(sheet, animated: true)
            })
        }
        done.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(done, animated: true)
    }

    private func failed(_ error: Error) {
        task = nil
        setBusy(false)
        progress.isHidden = true
        status.text = error is CancellationError ? "Stopped." : "It could not be made: \(error.localizedDescription)"
        onSaved?()
    }
}

private extension UILabel {
    static func plain(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15)
        label.textColor = .lightGray
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }
}
