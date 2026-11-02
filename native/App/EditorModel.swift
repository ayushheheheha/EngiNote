import PDFKit
import PencilKit
import SwiftUI

/// One open notebook. The pages are a PDFDocument shown by PDFView; each page gets a PencilKit canvas
/// laid over it (PDFPageOverlayViewProvider), and the system tool tray (PKToolPicker) draws with it.
@MainActor
final class EditorModel: NSObject, ObservableObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    let info: NotebookInfo
    let store: Store
    let document: PDFDocument
    let picker = PKToolPicker()
    weak var pdfView: PDFView?

    @Published var pageCount = 0
    @Published var fingerDraws = UserDefaults.standard.bool(forKey: "fingerDraws") {
        didSet {
            UserDefaults.standard.set(fingerDraws, forKey: "fingerDraws")
            for c in canvases.values { c.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly }
        }
    }

    private var saved: [PDFPage: Data] = [:]           // each page's drawing as last saved
    private var canvases: [PDFPage: PKCanvasView] = [:]
    private var pageOf: [ObjectIdentifier: PDFPage] = [:]
    private var dirty: Set<PDFPage> = []
    private var structureDirty = false
    private var saveTask: Task<Void, Never>?
    private weak var active: PKCanvasView?

    init(info: NotebookInfo, store: Store) {
        self.info = info
        self.store = store
        self.document = PDFDocument(url: store.pdfURL(info.id)) ?? PaperPDF.document(paper: info.paper, pages: 1)
        let data = store.readDrawings(info.id)
        for i in 0..<document.pageCount {
            if let p = document.page(at: i), i < data.count, !data[i].isEmpty { saved[p] = data[i] }
        }
        super.init()
        pageCount = document.pageCount
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        if let c = canvases[page] { return c }
        let c = PKCanvasView(frame: .zero)
        c.backgroundColor = .clear
        c.isOpaque = false
        c.isScrollEnabled = false   // fingers scroll and zoom the page, not the canvas
        c.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        c.delegate = self
        if let d = saved[page], let drawing = try? PKDrawing(data: d) { c.drawing = drawing }
        picker.addObserver(c)
        canvases[page] = c
        pageOf[ObjectIdentifier(c)] = page
        return c
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let c = overlayView as? PKCanvasView else { return }
        picker.setVisible(true, forFirstResponder: c)
        if active == nil || active?.window == nil {
            active = c
            DispatchQueue.main.async { c.becomeFirstResponder() }
        }
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        if let c = overlayView as? PKCanvasView, c === active { active = nil }
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if let p = pageOf[ObjectIdentifier(canvasView)] { dirty.insert(p) }
        scheduleSave()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        active = canvasView
        if !canvasView.isFirstResponder {
            DispatchQueue.main.async { canvasView.becomeFirstResponder() }
        }
    }

    // MARK: saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { self?.saveNow() }
        }
    }

    func saveNow() {
        saveTask?.cancel()
        if structureDirty {
            store.writePDF(document, id: info.id)
            structureDirty = false
        }
        for p in dirty {
            if let c = canvases[p] { saved[p] = c.drawing.strokes.isEmpty ? nil : c.drawing.dataRepresentation() }
        }
        dirty.removeAll()
        var all: [Data] = []
        for i in 0..<document.pageCount {
            if let p = document.page(at: i) { all.append(saved[p] ?? Data()) } else { all.append(Data()) }
        }
        store.writeDrawings(info.id, all)
        store.touch(info.id)
    }

    // MARK: pages

    var currentIndex: Int {
        guard let p = pdfView?.currentPage else { return 0 }
        return max(0, document.index(for: p))
    }

    func addPage() {
        let at = currentIndex
        let size = document.page(at: at)?.bounds(for: .mediaBox).size ?? CGSize(width: Paper.width, height: info.paper.pageHeight)
        let page = PaperPDF.blankPage(paper: info.paper, size: size)
        document.insert(page, at: at + 1)
        pageChanged(go: page)
    }

    func deleteCurrentPage() {
        guard document.pageCount > 1, let p = pdfView?.currentPage else { return }
        let at = document.index(for: p)
        document.removePage(at: at)
        if let c = canvases[p] { pageOf[ObjectIdentifier(c)] = nil }
        canvases[p] = nil
        saved[p] = nil
        dirty.remove(p)
        pageChanged(go: document.page(at: min(at, document.pageCount - 1)))
    }

    private func pageChanged(go page: PDFPage?) {
        structureDirty = true
        pageCount = document.pageCount
        pdfView?.layoutDocumentView()
        if let page { pdfView?.go(to: page) }
        saveNow()
    }

    func go(to index: Int) {
        if let p = document.page(at: index) { pdfView?.go(to: p) }
    }

    func thumbnail(_ index: Int, width: CGFloat) -> UIImage? {
        guard let p = document.page(at: index) else { return nil }
        let box = p.bounds(for: .mediaBox)
        let size = CGSize(width: width, height: width * box.height / max(box.width, 1))
        let base = p.thumbnail(of: size, for: .mediaBox)
        guard let d = drawing(for: p), !d.strokes.isEmpty else { return base }
        let ink = d.image(from: CGRect(origin: .zero, size: box.size), scale: size.width / box.width)
        return UIGraphicsImageRenderer(size: size).image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: undo / redo (the canvas in use)

    private var undoer: UndoManager? { active?.undoManager ?? pdfView?.window?.undoManager }
    func undo() { undoer?.undo() }
    func redo() { undoer?.redo() }

    // MARK: export

    private func drawing(for p: PDFPage) -> PKDrawing? {
        if let c = canvases[p] { return c.drawing }
        if let d = saved[p] { return try? PKDrawing(data: d) }
        return nil
    }

    /// The notebook as one flat PDF: the pages with the ink drawn on them.
    func exportPDF() -> URL? {
        guard let first = document.page(at: 0) else { return nil }
        let name = info.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.bounds(for: .mediaBox).size))
        do {
            try renderer.writePDF(to: url) { ctx in
                for i in 0..<document.pageCount {
                    guard let p = document.page(at: i) else { continue }
                    let box = p.bounds(for: .mediaBox)
                    let rect = CGRect(origin: .zero, size: box.size)
                    ctx.beginPage(withBounds: rect, pageInfo: [:])
                    let c = ctx.cgContext
                    c.saveGState()
                    c.translateBy(x: 0, y: box.height)
                    c.scaleBy(x: 1, y: -1)
                    p.draw(with: .mediaBox, to: c)
                    c.restoreGState()
                    if let d = drawing(for: p), !d.strokes.isEmpty {
                        d.image(from: rect, scale: 2).draw(in: rect)
                    }
                }
            }
            return url
        } catch {
            return nil
        }
    }
}
