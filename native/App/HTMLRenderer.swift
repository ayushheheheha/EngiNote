import PDFKit
import UIKit
import WebKit

/// Turns an HTML page into PDF pages (900 wide, A4 tall), so it can be written on like any notebook.
/// WebKit is used only as the page renderer here, off screen; the text stays sharp (vector).
@MainActor
final class HTMLRenderer: NSObject, WKNavigationDelegate {
    static let pageHeight: CGFloat = 1273   // A4 at 900 wide, the same as the web app's page

    private var loaded: CheckedContinuation<Void, Never>?
    private let web: WKWebView

    private let cut: CGFloat   // how tall each page is cut

    private init(height: CGFloat) {
        cut = height
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: Paper.width, height: height), configuration: WKWebViewConfiguration())
        super.init()
        web.navigationDelegate = self
    }

    /// `gaps`: the room opened in the page for writing (the web app's `gaps`), put back before the pages are cut.
    /// `height`: how tall a page is (the promo cover is one 16:9 page).
    static func document(html: String, base: URL?, gaps: [[String: Any]] = [], height: CGFloat = pageHeight) async -> PDFDocument? {
        await HTMLRenderer(height: height).render(html, base, gaps)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
    private func finish() { loaded?.resume(); loaded = nil }

    private static let gapJS = #"""
    (function (gaps) {
      const places = gaps.map(function (g) { let el = document.body; for (const i of g.path) { el = el && el.children[i]; } return el; });
      gaps.forEach(function (g, i) {
        const after = places[i];
        if (!after || after === document.body) return;
        const d = document.createElement('div');
        d.setAttribute('style', 'width:100%!important;height:' + Math.max(0, g.height - (g.trim || 0)) + 'px!important;min-height:0!important;max-height:none!important;margin:0!important;padding:0!important;border:0!important;background:none!important;');
        after.after(d);
      });
    })
    """#

    private func render(_ html: String, _ base: URL?, _ gaps: [[String: Any]]) async -> PDFDocument? {
        // a web view that is in a window lays itself out properly; this one is invisible
        if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            web.alpha = 0.01
            win.insertSubview(web, at: 0)
        }
        defer { web.removeFromSuperview() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loaded = c
            web.loadHTMLString(html, baseURL: base)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)   // pictures and fonts
        if !gaps.isEmpty, let json = try? JSONSerialization.data(withJSONObject: gaps), let text = String(data: json, encoding: .utf8) {
            _ = try? await web.evaluateJavaScript(Self.gapJS + "(\(text))")
        }
        let measured = try? await web.evaluateJavaScript("Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)")
        let total = min(max(CGFloat((measured as? Double) ?? Double(cut)), 1), cut * 150)
        web.frame = CGRect(x: 0, y: 0, width: Paper.width, height: total)
        try? await Task.sleep(nanoseconds: 300_000_000)

        let pageCount = Int((total / cut).rounded(.up))
        var slices: [PDFPage] = []
        var keep: [PDFDocument] = []   // a page needs its document alive
        for k in 0..<pageCount {
            let cfg = WKPDFConfiguration()
            cfg.rect = CGRect(x: 0, y: CGFloat(k) * cut, width: Paper.width, height: cut)
            if let data = try? await web.pdf(configuration: cfg), let d = PDFDocument(data: data), let p = d.page(at: 0) {
                keep.append(d)
                slices.append(p)
            }
        }
        guard !slices.isEmpty else { return nil }
        // drawn into one new PDF, so the result stands alone (text stays vector)
        let rect = CGRect(x: 0, y: 0, width: Paper.width, height: cut)
        let data = UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            for p in slices {
                ctx.beginPage()
                let c = ctx.cgContext
                UIColor.white.setFill()
                c.fill(rect)
                c.saveGState()
                c.translateBy(x: 0, y: rect.height)
                c.scaleBy(x: 1, y: -1)
                p.draw(with: .mediaBox, to: c)
                c.restoreGState()
            }
        }
        _ = keep
        return PDFDocument(data: data)
    }
}
