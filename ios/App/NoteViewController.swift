import AVKit
import UIKit
import WebKit

/// The whole screen: a web view showing the web app, edge to edge with no bars.
///
/// What this adds to the web app:
///  - Apple Pencil double-tap and squeeze. A web page is never told about them, so they are
///    passed on as a 'pencil' event on the page's window (see app.js).
///  - The dialogs behind confirm() and alert(), which a bare web view simply does not show
///    (confirm() would answer "no" by itself, so nothing could ever be deleted).
///  - Saving a file. A page in a web view cannot download anything, so the page hands over the
///    backup's name and text (the 'saveFile' message in app.js) and this asks where to keep it.
///  - Recording the screen as a 16:9 movie (Recorder.swift), started and stopped by the page
///    (the 'recorder' message), which is told how it goes (a 'recorder' event on its window).
///  - The recordings themselves: the page lists them as a folder, and asks for one to be played,
///    shared or deleted (the 'recordings' message; the list goes back as a 'recordings' event).
///  - The mic check: the page asks to be shown how loud the microphone's sound is (the 'mic'
///    message) and is sent the levels, or why not, as 'mic' events (Recorder.swift).
///  - The camera bubble (CameraBubble.swift), switched on and off and given its shape by the page
///    (the 'camera' message), which is told the outcome (a 'camera' event).
final class NoteViewController: UIViewController, WKUIDelegate, WKScriptMessageHandler, UIPencilInteractionDelegate {
    private var webView: WKWebView!
    private let recorder = Recorder()
    private let camera = CameraBubble()

    // A note-taking surface: no status bar, the home bar stays out of the way, and a swipe from
    // the bottom edge needs a second swipe, so writing near the edge does not leave the app.
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(WebFiles(), forURLScheme: WebFiles.scheme)
        configuration.userContentController.add(self, name: "saveFile")
        configuration.userContentController.add(self, name: "recorder")
        configuration.userContentController.add(self, name: "recordings")
        configuration.userContentController.add(self, name: "mic")
        configuration.userContentController.add(self, name: "camera")

        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.allowsLinkPreview = false
        webView.isInspectable = true // lets Safari's Web Inspector on a Mac attach, for debugging
        // The page lays itself out to the window and scrolls its own content: the web view must not
        // scroll, bounce or inset it.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)
        view.addSubview(camera) // over the page; hidden until the page asks for it

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        recorder.onFailure = { [weak self] message in self?.stopRecording(because: message) }
        recorder.onLevels = { [weak self] levels in self?.send("mic", ["levels": levels]) }
        recorder.onCheckFailed = { [weak self] reason in self?.send("mic", ["on": false, "message": reason]) }
        camera.onNews = { [weak self] on, problem in
            guard let self = self else { return }
            var news: [String: Any] = ["on": on, "shape": self.camera.shape]
            if let problem = problem { news["message"] = problem }
            self.send("camera", news)
        }
        // iPadOS stops handing over the screen once the app is no longer in front: close the movie properly.
        NotificationCenter.default.addObserver(self, selector: #selector(wentToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cameBack), name: UIApplication.didBecomeActiveNotification, object: nil)

        webView.load(URLRequest(url: WebFiles.home))
    }

    // MARK: Apple Pencil

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        // "Off" in Settings > Apple Pencil means off here too.
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        tellPage("tap")
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
        tellPage("squeeze")
    }

    private func tellPage(_ gesture: String) {
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('pencil', { detail: '\(gesture)' }))", completionHandler: nil)
    }

    /// An event on the page's window with `detail` as its detail. The detail travels as JSON, so
    /// whatever text is in it (an error message, say) cannot become code.
    private func send(_ event: String, _ detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('\(event)', { detail: \(json) }))", completionHandler: nil)
    }

    // MARK: Recording

    private func record(_ body: [String: Any]) {
        switch body["action"] as? String {
        case "start":
            let microphone = body["microphone"] as? Bool ?? true
            recorder.start(
                quality: body["quality"] as? String ?? "standard", wide: body["wide"] as? Bool ?? true,
                microphone: microphone, enhance: body["enhance"] as? Bool ?? false
            ) { [weak self] error, note in
                guard let self = self else { return }
                if let error = error {
                    self.send("recorder", ["state": "idle", "message": "Recording did not start: \(error)"])
                    return
                }
                UIApplication.shared.isIdleTimerDisabled = true // the screen must not lock in the middle of a lecture
                var news: [String: Any] = ["state": "recording"]
                if let note = note { news["message"] = note }
                self.send("recorder", news)
                // A voice that is not arriving must not be found out an hour later: look after a few seconds.
                guard microphone else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self = self, self.recorder.isActive, !self.recorder.isPaused, !self.recorder.hasSound else { return }
                    self.send("recorder", ["state": "recording", "message": "Warning: no sound is being recorded. Stop and start again; if it stays silent, switch Enhance the other way."])
                }
            }
        case "pause" where recorder.isActive:
            recorder.pause()
            send("recorder", ["state": "paused"])
        case "resume" where recorder.isActive:
            recorder.resume()
            send("recorder", ["state": "recording"])
        case "stop":
            stopRecording(because: nil)
        default:
            // Asked to pause or resume a recording that is no longer running: say how things stand.
            send("recorder", ["state": "idle"])
        }
    }

    /// Stop, finish the movie and tell the page. `problem`: why, if it was not the user's choice.
    private func stopRecording(because problem: String?) {
        guard recorder.isActive else {
            send("recorder", ["state": "idle"])
            return
        }
        // Finishing the file may outlast the app being in front: ask iPadOS for the time to do it.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        recorder.stop { [weak self] file, error in
            UIApplication.shared.isIdleTimerDisabled = false
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
            guard let self = self else { return }
            let trouble = problem ?? error
            let place = "Files, under On My iPad > EngiNote"
            let message: String
            if file == nil {
                message = "Recording failed: \(trouble ?? "nothing was recorded")."
            } else if let trouble = trouble {
                message = "Recording stopped: \(trouble). What was recorded is in \(place)."
            } else {
                message = "Recording saved. It is also in \(place)."
            }
            self.send("recorder", ["state": "idle", "message": message])

            // Offer to send the movie somewhere at once.
            if let file = file, UIApplication.shared.applicationState == .active { self.share(file) }
        }
    }

    /// The system's share sheet for a movie: save to Photos or Files, an editing app, AirDrop.
    private func share(_ file: URL) {
        guard presentedViewController == nil else { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1)
        present(sheet, animated: true)
    }

    @objc private func wentToBackground() {
        if recorder.isActive { stopRecording(because: "the app was no longer on screen") }
        recorder.leftScreen(true) // a mic check lets go of the microphone
    }

    // In front again (also after a system question or Control Centre, when there is nothing to do).
    @objc private func cameBack() {
        recorder.leftScreen(false)
        camera.wake()
    }

    // The iPad turned, or the app's window resized: the camera bubble must still be wholly on screen.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        camera.place()
    }

    // MARK: The camera bubble

    private func showCamera(_ body: [String: Any]) {
        if let shape = body["shape"] as? String { camera.reshape(shape) } // a name it does not know changes nothing
        if body["on"] as? Bool == true {
            camera.turnOn()
        } else {
            camera.turnOff()
        }
    }

    // MARK: The recordings folder

    /// The recording the page means by `name`: a movie directly in the recordings folder that is
    /// not being written at the moment, and nothing else, whatever the name says.
    private func recording(named name: Any?) -> URL? {
        guard let name = name as? String, let folder = try? Recorder.folder() else { return nil }
        let file = folder.appendingPathComponent((name as NSString).lastPathComponent)
        guard file.pathExtension.lowercased() == "mov",
              file.lastPathComponent != recorder.activeFile?.lastPathComponent,
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    /// Play, share or delete one recording, as the page asks; then, whatever was asked (also just
    /// "list"), send the page the list as it now stands.
    private func recordings(_ body: [String: Any]) {
        if let file = recording(named: body["name"]) {
            switch body["action"] as? String {
            case "play":
                if presentedViewController == nil {
                    let player = AVPlayerViewController()
                    player.player = AVPlayer(url: file)
                    present(player, animated: true) { player.player?.play() }
                }
            case "share":
                share(file)
            case "delete": // the page has already asked the user if they are sure
                try? FileManager.default.removeItem(at: file)
            default:
                break
            }
        }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let active = recorder.activeFile?.lastPathComponent
        var found: [URL] = []
        if let folder = try? Recorder.folder() {
            found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }
        let files: [[String: Any]] = found
            .filter { $0.pathExtension.lowercased() == "mov" && $0.lastPathComponent != active }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                return ["name": url.lastPathComponent, "size": values?.fileSize ?? 0, "modified": modified * 1000]
            }
        send("recordings", ["files": files])
    }

    // MARK: Messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the app's own page may ask: never a frame inside it.
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "saveFile": saveFile(body)
        case "recorder": record(body)
        case "recordings": recordings(body)
        case "mic": recorder.check(on: body["on"] as? Bool ?? false, enhance: body["enhance"] as? Bool ?? false)
        case "camera": showCamera(body)
        default: break
        }
    }

    // MARK: Saving a file

    private func saveFile(_ body: [String: Any]) {
        guard let name = body["name"] as? String, let text = body["text"] as? String else { return }

        // Written to a folder of its own, so that the copy the user saves carries exactly this name.
        // ponytail: these temporary copies are left for iPadOS to clear; delete them here if they ever add up.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent((name as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        } catch {
            let dialog = UIAlertController(title: "The backup could not be saved", message: error.localizedDescription, preferredStyle: .alert)
            dialog.addAction(UIAlertAction(title: "OK", style: .default))
            present(dialog, animated: true)
            return
        }
        // The system's "save to Files" sheet: the user picks the place, the app keeps its own copy.
        present(UIDocumentPickerViewController(forExporting: [file], asCopy: true), animated: true)
    }

    // MARK: confirm() and alert()

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let dialog = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        dialog.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(dialog, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let dialog = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(dialog, animated: true)
    }
}
