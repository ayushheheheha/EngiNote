import UIKit
import WebKit

/// The in-app browser: a web view of its own, with a slim bar (back, forward, reload, home, address), that the
/// page lays over the note's window (the 'browser' message, browser.js). It is the app's own view above the web
/// view, so a site shown in it is a normal site: nothing stops it from loading, and its logins are kept like Safari's.
/// Being on the screen it is in a recording of the screen.
///
/// The page decides where it goes and whether it is there at all; this only draws it and browses. It is made the
/// first time it is asked for and then kept, so closing it and opening it again finds the site where it was left.
///
/// None of this can be run off the device: it was written against the documentation and is only proven on the iPad.
final class BrowserPane: UIView, WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate {
    /// Where it opens first, and where the house button goes.
    static let home = URL(string: "https://engikode.vercel.app")!

    /// The pane's own "Note" button was tapped: the page is told, as it owns whether the browser is open.
    var onClose: (() -> Void)?
    /// Where an alert or a question from the site is shown.
    weak var presenter: UIViewController?

    private(set) var isOpen = false

    private static let barHeight: CGFloat = 52

    private let web: WKWebView
    private let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let address = UITextField()
    private let note = UIButton(type: .system)
    private let back = UIButton(type: .system)
    private let forward = UIButton(type: .system)
    private let reload = UIButton(type: .system)
    private let home = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let toast = UILabel()
    private var toastTimer: Timer?
    private var watching: [NSKeyValueObservation] = []
    private var started = false

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Some sites (Google's sign-in, say) turn away a web view that does not call itself Safari.
        configuration.applicationNameForUserAgent = "Version/17.5 Safari/605.1.15"
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        backgroundColor = .systemBackground
        clipsToBounds = true
        isHidden = true

        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
        addSubview(web)
        addSubview(bar)
        bar.contentView.addSubview(progress)

        func style(_ button: UIButton, _ symbol: String, _ label: String, _ action: Selector) {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            button.configuration = configuration
            button.accessibilityLabel = label
            button.addTarget(self, action: action, for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        }
        style(back, "chevron.left", "Back", #selector(goBack))
        style(forward, "chevron.right", "Forward", #selector(goForward))
        style(reload, "arrow.clockwise", "Reload", #selector(reloadOrStop))
        style(home, "house", "Home", #selector(goHome))

        var close = UIButton.Configuration.tinted()
        close.title = "Note"
        close.image = UIImage(systemName: "square.and.pencil")
        close.imagePadding = 6
        close.cornerStyle = .capsule
        note.configuration = close
        note.accessibilityLabel = "Back to the note"
        note.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        address.delegate = self
        address.backgroundColor = .secondarySystemFill
        address.layer.cornerRadius = 10
        address.font = .systemFont(ofSize: 15)
        address.keyboardType = .webSearch
        address.returnKeyType = .go
        address.autocapitalizationType = .none
        address.autocorrectionType = .no
        address.clearButtonMode = .whileEditing
        address.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        address.leftViewMode = .always
        address.accessibilityLabel = "Address"
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let row = UIStackView(arrangedSubviews: [note, back, forward, reload, home, address])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: bar.contentView.centerYAnchor),
        ])

        toast.font = .systemFont(ofSize: 15, weight: .medium)
        toast.textColor = .white
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        toast.textAlignment = .center
        toast.numberOfLines = 2
        toast.layer.cornerRadius = 16
        toast.clipsToBounds = true
        toast.alpha = 0
        addSubview(toast)

        watching = [
            web.observe(\.canGoBack, options: [.initial, .new]) { [weak self] web, _ in self?.back.isEnabled = web.canGoBack },
            web.observe(\.canGoForward, options: [.initial, .new]) { [weak self] web, _ in self?.forward.isEnabled = web.canGoForward },
            web.observe(\.isLoading, options: [.initial, .new]) { [weak self] web, _ in self?.loading(web.isLoading) },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in self?.progress.setProgress(Float(web.estimatedProgress), animated: true) },
            web.observe(\.url, options: [.new]) { [weak self] web, _ in self?.showAddress(web.url) },
        ]
    }

    required init?(coder: NSCoder) { fatalError("BrowserPane is made in code") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        progress.frame = CGRect(x: 0, y: Self.barHeight - 2, width: bounds.width, height: 2)
        web.frame = CGRect(x: 0, y: Self.barHeight, width: bounds.width, height: max(0, bounds.height - Self.barHeight))
        let width = min(bounds.width - 40, 520)
        toast.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height - 64, width: width, height: 44)
    }

    // MARK: Being there

    /// Show the browser at `rect` (the root view's coordinates). `held`: the page has something of its own to show
    /// over it just now (a menu, the recording countdown), so it steps aside, without a fade, and comes back as it was.
    func open(at rect: CGRect, held: Bool) {
        frame = rect
        if !started {
            started = true
            web.load(URLRequest(url: Self.home))
        }
        if held {
            endEditing(true)
            isHidden = true
            return
        }
        if !isOpen || isHidden {
            let fade = !isOpen
            alpha = fade ? 0 : 1
            isHidden = false
            if fade { UIView.animate(withDuration: 0.18) { self.alpha = 1 } }
        }
        isOpen = true
    }

    func close() {
        guard isOpen || !isHidden else { return }
        isOpen = false
        endEditing(true)
        UIView.animate(withDuration: 0.15, animations: { self.alpha = 0 }) { done in
            if !self.isOpen { self.isHidden = true }
        }
    }

    /// A short message over the foot of the pane: the page's own messages (a recording failed, say) would be hidden behind it.
    func say(_ text: String) {
        toast.text = text
        toastTimer?.invalidate()
        UIView.animate(withDuration: 0.15) { self.toast.alpha = 1 }
        toastTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.3) { self?.toast.alpha = 0 }
        }
    }

    // MARK: Browsing

    @objc private func goBack() { web.goBack() }
    @objc private func goForward() { web.goForward() }
    @objc private func goHome() { web.load(URLRequest(url: Self.home)) }
    @objc private func closeTapped() { onClose?() }
    @objc private func reloadOrStop() { web.isLoading ? web.stopLoading() : web.reload() }

    private func loading(_ on: Bool) {
        reload.configuration?.image = UIImage(systemName: on ? "xmark" : "arrow.clockwise")
        reload.accessibilityLabel = on ? "Stop" : "Reload"
        if !on { progress.setProgress(0, animated: false) }
    }

    private func showAddress(_ url: URL?) {
        guard !address.isFirstResponder, let url = url else { return }
        address.text = url.absoluteString.replacingOccurrences(of: "https://", with: "")
    }

    /// An address as typed: a web address (with or without https://), else a search.
    static func destination(for text: String) -> URL? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if let url = URL(string: typed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url }
        if !typed.contains(" "), typed.contains("."), let url = URL(string: "https://" + typed) { return url }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: typed)]
        return search.url
    }

    func textFieldDidBeginEditing(_ field: UITextField) {
        field.text = web.url?.absoluteString
        DispatchQueue.main.async { field.selectAll(nil) }
    }

    func textFieldDidEndEditing(_ field: UITextField) { showAddress(web.url) }

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
        if let url = Self.destination(for: field.text ?? "") { web.load(URLRequest(url: url)) }
        field.resignFirstResponder()
        return true
    }

    // MARK: The web view's delegates

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        switch url.scheme?.lowercased() {
        case "http", "https", "about", "blob", "data":
            decisionHandler(.allow)
        default: // mailto:, tel:, a link into another app: not for a web view
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    // A link that wants a window of its own opens here instead: there is only the one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled, code != 102 else { return } // 102: a download or a plug-in took the page over
        say("Could not open that page: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter = presenter, presenter.presentedViewController == nil else { return completionHandler() }
        let dialog = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presenter.present(dialog, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let presenter = presenter, presenter.presentedViewController == nil else { return completionHandler(false) }
        let dialog = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        dialog.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presenter.present(dialog, animated: true)
    }
}
