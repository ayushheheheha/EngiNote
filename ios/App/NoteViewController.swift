import UIKit
import WebKit

/// The whole screen: a web view showing the web app, edge to edge with no bars.
///
/// What this adds to the web app:
///  - Apple Pencil double-tap and squeeze. A web page is never told about them, so they are
///    passed on as a 'pencil' event on the page's window (see app.js).
///  - The dialogs behind confirm() and alert(), which a bare web view simply does not show
///    (confirm() would answer "no" by itself, so nothing could ever be deleted).
final class NoteViewController: UIViewController, WKUIDelegate, UIPencilInteractionDelegate {
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
