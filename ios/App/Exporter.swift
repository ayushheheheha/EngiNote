import PDFKit
import UIKit
import WebKit

/// Makes a PDF of a note: the page hands over the note with its ink as one HTML document
/// (export.js) and how tall each page of the PDF is to be.
///
/// The document is loaded in a web view of its own, out of sight, as wide as a note is laid out,
/// with JavaScript off: it holds an imported file, which is not trusted. Each page of the PDF is
/// then a picture of one stretch of that document, exactly its size, and the pages are put
/// together into one file.
final class Exporter: NSObject, WKNavigationDelegate {
    /// The width every note is laid out at: PAGE_WIDTH in app.js.
    static let width: CGFloat = 900

    private var webView: WKWebView?
    private var rects: [CGRect] = []   // the stretch of the document that each page shows, top to bottom
    private var parts: [Data] = []     // the pages made so far: each a PDF of one page
    private var loaded = false
    private var finish: ((Data?, String?) -> Void)?

    /// Make the PDF. `heights`: how tall each page is, in the document's px; the pages lie one
    /// under the other in it. `host`: a view on screen, which the web view is put at the very back
    /// of (one that is in no window may never be drawn). `finish` is given the PDF, or why there
    /// is none. One export at a time.
    func makePDF(html: String, heights: [CGFloat], under host: UIView, finish: @escaping (Data?, String?) -> Void) {
        guard webView == nil else {
            finish(nil, "another export is still being made")
            return
        }
        var top: CGFloat = 0
        rects = []
        for height in heights {
            rects.append(CGRect(x: 0, y: top, width: Exporter.width, height: height))
            top += height
        }
        parts = []
        loaded = false
        self.finish = finish

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // As a phone lays a page out: at the width the document asks for (900, in its viewport line).
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: Exporter.width, height: 1200), configuration: configuration)
        view.navigationDelegate = self
        view.isUserInteractionEnabled = false
        host.insertSubview(view, at: 0) // behind everything: the app's own page covers it
        webView = view
        view.loadHTMLString(html, baseURL: nil)
        // Something the file asks the network for may never come: after a while, go on without it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak view] in
            guard let self = self, let view = view, self.webView === view, !self.loaded else { return }
            self.loaded = true
            self.nextPage()
        }
    }

    // MARK: Loading the document

    // The document itself and nothing after it: a file must not send this web view somewhere else.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let ours = navigationAction.targetFrame?.isMainFrame == true && !loaded
        let inside = navigationAction.targetFrame?.isMainFrame == false // a frame inside the file, as the editor shows it
        decisionHandler(ours || inside ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !loaded else { return }
        loaded = true
        // A moment for the pictures in it to be laid out and drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.nextPage() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        end(nil, error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        end(nil, error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        end(nil, "the note is too large for this iPad's memory")
    }

    // MARK: Making the pages

    /// Make the next page; when there are no more, put them together and finish.
    private func nextPage() {
        guard let webView = webView else { return }
        guard parts.count < rects.count else {
            let whole = merged()
            end(whole, whole == nil ? "the pages could not be put together" : nil)
            return
        }
        let configuration = WKPDFConfiguration()
        configuration.rect = rects[parts.count]
        webView.createPDF(configuration: configuration) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.parts.append(data)
                self.nextPage()
            case .failure(let error):
                self.end(nil, error.localizedDescription)
            }
        }
    }

    /// The pages as one PDF.
    private func merged() -> Data? {
        if parts.count == 1 { return parts[0] }
        let whole = PDFDocument()
        var sources: [PDFDocument] = [] // kept until the whole is written out: a page belongs to the document it came from
        for part in parts {
            guard let source = PDFDocument(data: part), let page = source.page(at: 0) else { return nil }
            sources.append(source)
            whole.insert(page, at: whole.pageCount)
        }
        let data = whole.dataRepresentation()
        sources.removeAll()
        return data
    }

    private func end(_ data: Data?, _ problem: String?) {
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        rects = []
        parts = []
        let finish = self.finish
        self.finish = nil
        finish?(data, problem)
    }
}
