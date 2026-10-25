import Foundation
import WebKit

/// Serves the web app (the "web" folder inside the app bundle) to the web view at
/// enginote://app/... , so that it runs with no network and no web server.
///
/// The web app saves notes in the web view's storage, and that storage is kept per address.
/// So this scheme and host must NEVER change: under any other address the saved notes would still
/// be on the iPad but the app would no longer see them.
final class WebFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "enginote"
    static let home = URL(string: "enginote://app/index.html")!

    /// Where files shared to the app wait for the page to fetch them (NoteViewController.receive).
    static let sharedFolder = FileManager.default.temporaryDirectory.appendingPathComponent("shared", isDirectory: true)

    private let root: URL = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true).standardizedFileURL

    /// For developing from the PC: a file in the app's Documents/dev-web folder (put there over the USB cable, and
    /// visible in the Files app) is served in place of the bundled one of the same name. No such folder, no change.
    private let dev: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev-web", isDirectory: true).standardizedFileURL

    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "pdf": "application/pdf",
    ]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
        // The web folder, or (under /shared/) the files shared to the app.
        let shared = path.hasPrefix("/shared/")
        let base = (shared ? WebFiles.sharedFolder : root).standardizedFileURL
        let relative = String(path.dropFirst(shared ? "/shared/".count : 1))
        var file = base.appendingPathComponent(relative).standardizedFileURL
        if !shared {
            let override = dev.appendingPathComponent(relative).standardizedFileURL
            if override.path.hasPrefix(dev.path + "/"), FileManager.default.fileExists(atPath: override.path) { file = override }
        }

        // Only files inside that folder, whatever the path says.
        guard file.path.hasPrefix(base.path + "/") || file.path.hasPrefix(dev.path + "/"), let data = try? Data(contentsOf: file) else {
            respond(to: urlSchemeTask, url: url, status: 404, type: "text/plain; charset=utf-8", body: Data("Not found".utf8))
            return
        }
        let type = WebFiles.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        respond(to: urlSchemeTask, url: url, status: 200, type: type, body: data)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Every request is answered at once in start; there is nothing to cancel.
    }

    private func respond(to task: WKURLSchemeTask, url: URL, status: Int, type: String, body: Data) {
        let headers = [
            "Content-Type": type,
            "Content-Length": String(body.count),
            "Cache-Control": "no-cache", // an updated app must show its new files, not cached old ones
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
