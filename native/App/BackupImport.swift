import PDFKit
import PencilKit
import UIKit

/// Reads an EngiNote backup (the .json the web app saves) and turns its notebooks into native ones:
/// blank-paper and PDF notebooks come across with their pen strokes. Notes made from an imported web
/// page, and text boxes and pictures placed on a note, are not converted (they are counted in the report).
enum BackupImport {
    @MainActor
    static func run(url: URL, store: Store, progress: @escaping (String) -> Void) async throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["app"] as? String == "EngiNote", let docs = root["docs"] as? [[String: Any]] else {
            return "That file is not an EngiNote backup."
        }
        var made = 0, existing = 0, web = 0, items = 0, folders = 0
        for d in docs where d["type"] as? String == "folder" {
            guard let id = d["id"] as? String, let name = d["name"] as? String else { continue }
            if !store.hasFolder(id) { store.addFolder(name: name, id: id); folders += 1 }
        }
        let notes = docs.filter { $0["type"] as? String != "folder" }
        for (n, d) in notes.enumerated() {
            guard let id = d["id"] as? String, let name = d["name"] as? String else { continue }
            progress("Importing \(n + 1) of \(notes.count): \(name)")
            await Task.yield()
            if store.hasNotebook(id) { existing += 1; continue }
            if let list = d["items"] as? [Any], !list.isEmpty { items += list.count }
            if let pages = d["pages"] as? [[String: Any]], !pages.isEmpty {
                if convert(d, id: id, name: name, pages: pages, store: store) { made += 1 }
            } else if let html = d["html"] as? String, !html.isEmpty {
                if await convertHTML(d, id: id, name: name, html: html, store: store) { made += 1 } else { web += 1 }
            } else {
                web += 1
            }
        }
        var lines = ["Imported \(made) notebook\(made == 1 ? "" : "s") and \(folders) folder\(folders == 1 ? "" : "s")."]
        if existing > 0 { lines.append("\(existing) already here, left as they are.") }
        if web > 0 { lines.append("\(web) note\(web == 1 ? "" : "s") made from web pages could not be read.") }
        if items > 0 { lines.append("\(items) text box\(items == 1 ? "" : "es") or picture\(items == 1 ? "" : "s") placed on notes were left out.") }
        return lines.joined(separator: "\n")
    }

    private static func paper(from d: [String: Any]?) -> Paper {
        var p = Paper()
        guard let d else { return p }
        if let s = d["size"] as? String, Paper.sizes.contains(s) { p.size = s }
        p.horizontal = d["direction"] as? String == "horizontal"
        if let t = d["template"] as? String, Paper.templates.contains(t) { p.template = t }
        if let c = d["color"] as? String { p.color = c }
        if let l = d["line"] as? String { p.line = l }
        if let s = d["spacing"] as? Double { p.spacing = min(8, max(1, Int(s))) }
        return p
    }

    private static func dataURL(_ s: String) -> Data? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(s[s.index(after: comma)...]))
    }

    @MainActor
    private static func convert(_ d: [String: Any], id: String, name: String, pages: [[String: Any]], store: Store) -> Bool {
        let p = paper(from: d["paper"] as? [String: Any])
        let source = (d["pdfFile"] as? String).flatMap(dataURL).flatMap { PDFDocument(data: $0) }
        let out = PDFDocument()
        var tops: [Double] = [], scales: [Double] = []
        var top = 0.0
        for (i, pg) in pages.enumerated() {
            let h = (pg["h"] as? Double) ?? p.pageHeight
            var page: PDFPage?
            if let n = pg["n"] as? Int, n > 0, let src = source?.page(at: n - 1) {
                page = src.copy() as? PDFPage
            } else if let img = (pg["img"] as? String).flatMap(dataURL).flatMap({ UIImage(data: $0) }) {
                page = PDFPage(image: img)
            }
            if page == nil {
                let tpl = pg["tpl"] as? String
                let bg = pg["bg"] as? String
                page = PaperPDF.blankPage(paper: p, size: CGSize(width: Paper.width, height: h),
                                          template: tpl.flatMap { Paper.templates.contains($0) ? $0 : nil }, color: bg)
            }
            guard let page else { return false }
            out.insert(page, at: i)
            tops.append(top)
            scales.append(page.bounds(for: .mediaBox).width / Paper.width)
            top += h
        }
        let drawings = inkData(d, tops: tops, scales: scales)
        let ms = (d["updatedAt"] as? Double) ?? Date().timeIntervalSince1970 * 1000
        let folder = (d["folder"] as? String).flatMap { store.hasFolder($0) ? $0 : nil }
        return store.add(id: id, name: name, paper: p, folderID: folder, updatedAt: Date(timeIntervalSince1970: ms / 1000),
                         document: out, drawings: drawings) != nil
    }


    /// The note's strokes, each put on the page it starts on, as one PencilKit drawing per page.
    private static func inkData(_ d: [String: Any], tops: [Double], scales: [Double]) -> [Data] {
        var perPage = [[PKStroke]](repeating: [], count: tops.count)
        for s in (d["strokes"] as? [[String: Any]]) ?? [] {
            guard let pts = s["points"] as? [[Double]], let y0 = pts.first, y0.count >= 2 else { continue }
            let idx = min(tops.lastIndex { $0 <= y0[1] } ?? 0, tops.count - 1)
            if let stroke = makeStroke(s, points: pts, top: tops[idx], scale: scales[idx]) { perPage[idx].append(stroke) }
        }
        return perPage.map { $0.isEmpty ? Data() : PKDrawing(strokes: $0).dataRepresentation() }
    }

    /// A note made from an imported web page: the page is drawn into PDF pages and the ink laid over it.
    @MainActor
    static func convertHTML(_ d: [String: Any], id: String, name: String, html: String, store: Store) async -> Bool {
        let gaps = (d["gaps"] as? [[String: Any]]) ?? []
        guard let doc = await HTMLRenderer.document(html: html, base: nil, gaps: gaps) else { return false }
        let n = doc.pageCount
        let tops = (0..<n).map { Double($0) * Double(HTMLRenderer.pageHeight) }
        let drawings = inkData(d, tops: tops, scales: [Double](repeating: 1, count: n))
        var p = Paper()
        p.template = "plain"
        let ms = (d["updatedAt"] as? Double) ?? Date().timeIntervalSince1970 * 1000
        let folder = (d["folder"] as? String).flatMap { store.hasFolder($0) ? $0 : nil }
        return store.add(id: id, name: name, paper: p, folderID: folder, updatedAt: Date(timeIntervalSince1970: ms / 1000),
                         document: doc, drawings: drawings, imported: true) != nil
    }

    private static func makeStroke(_ s: [String: Any], points: [[Double]], top: Double, scale: Double) -> PKStroke? {
        let tool = s["tool"] as? String ?? "pen"
        let size = (s["size"] as? Double) ?? 3
        let opacity = (s["opacity"] as? Double) ?? 1
        let colour = UIColor(hex: s["color"] as? String ?? "#000000")
        let ink = tool == "highlighter"
            ? PKInk(.marker, color: colour)
            : PKInk(.pen, color: colour.withAlphaComponent(CGFloat(opacity)))
        var cps: [PKStrokePoint] = []
        for (i, pt) in points.enumerated() where pt.count >= 2 {
            let hasPressure = pt.count > 2
            let pressure = hasPressure ? pt[2] : 0.5
            var w = hasPressure ? size * (0.4 + 1.2 * pressure) : size
            if tool == "highlighter" { w = size * 2.5 }
            w *= scale
            cps.append(PKStrokePoint(location: CGPoint(x: pt[0] * scale, y: (pt[1] - top) * scale),
                                     timeOffset: Double(i) * 0.008, size: CGSize(width: w, height: w),
                                     opacity: 1, force: CGFloat(pressure), azimuth: 0, altitude: .pi / 2))
        }
        guard let first = cps.first else { return nil }
        if cps.count == 1 {
            cps.append(PKStrokePoint(location: first.location, timeOffset: 0.008, size: first.size,
                                     opacity: 1, force: first.force, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: cps, creationDate: Date()), transform: .identity, mask: nil)
    }
}
