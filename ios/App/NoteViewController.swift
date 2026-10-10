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
final class NoteViewController: UIViewController, WKUIDelegate, WKScriptMessageHandler, UIPencilInteractionDelegate {
    private var webView: WKWebView!

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

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

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

    // MARK: Saving a file

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the app's own page may ask: never a frame inside it.
        guard message.name == "saveFile", message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let name = body["name"] as? String, let text = body["text"] as? String else { return }

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
