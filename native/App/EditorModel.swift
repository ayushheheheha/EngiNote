import JavaScriptCore
import PDFKit
import PencilKit
import SwiftUI

enum Tool: Equatable {
    case pen(String)   // a pen of the tray, by its id
    case eraser, hand, text, lasso
}

/// One open notebook. The pages are a PDFDocument shown by PDFView; each page gets a PageOverlay
/// (text and pictures, a PencilKit canvas, the tools' marks) laid over it. The tray chooses the tool.
@MainActor
final class EditorModel: NSObject, ObservableObject, Identifiable, PDFPageOverlayViewProvider, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    @Published private(set) var info: NotebookInfo
    let store: Store
    let document: PDFDocument
    let id: String
    var folder: URL { store.dir(info.id) }

    @Published var tool: Tool { didSet { if tool != oldValue { toolChanged(from: oldValue) } } }
    private var previous: Tool
    @Published var pageCount = 0
    @Published var pageIndex = 0
    @Published var zoom: CGFloat = 1
    @Published var isFit = true
    @Published var hasSelection = false
    @Published var hasCover: Bool
    private weak var selected: PageOverlay?

    private var saved: [PDFPage: Data] = [:]            // each page's drawing as last saved
    private var items: [PDFPage: [Item]] = [:]
    private var overlays: [PDFPage: PageOverlay] = [:]
    private var dirty: Set<PDFPage> = []
    private var structureDirty = false, itemsDirty = false
    private var saveTask: Task<Void, Never>?
    private var quiet = false

    init(info: NotebookInfo, store: Store) {
        self.info = info
        self.id = info.id
        self.store = store
        self.document = PDFDocument(url: store.pdfURL(info.id)) ?? PaperPDF.document(paper: info.paper, pages: 1)
        let prefs = Prefs.shared
        let pen = UserDefaults.standard.string(forKey: "pen").flatMap { prefs.pen($0) } ?? prefs.pens[0]
        tool = .pen(pen.id)
        previous = .pen(pen.id)
        hasCover = UserDefaults.standard.bool(forKey: "cover-" + info.id)
        let data = store.readDrawings(info.id), its = store.readItems(info.id)
        for i in 0..<document.pageCount {
            guard let p = document.page(at: i) else { continue }
            if i < data.count, !data[i].isEmpty { saved[p] = data[i] }
            if i < its.count, !its[i].isEmpty { items[p] = its[i] }
        }
        super.init()
        pageCount = document.pageCount
    }

    // MARK: the view

    private(set) lazy var view: PDFView = {
        let v = PDFView()
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.autoScales = true
        v.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1) : .systemGray5 }
        v.pageOverlayViewProvider = self
        v.isInMarkupMode = true
        v.document = document
        let watch = PenWatch(target: nil, action: nil)
        watch.down = { [weak self] t in self?.penDown(t) }
        watch.move = { [weak self] t in self?.penMoved(t) }
        watch.up = { [weak self] in self?.penUp() }
        v.addGestureRecognizer(watch)
        v.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        v.addInteraction(pencil)
        v.layer.addSublayer(ghost)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: v)
        NotificationCenter.default.addObserver(self, selector: #selector(pageTurned), name: .PDFViewPageChanged, object: v)
        // back where the note was left: the page and the zoom
        if let place = UserDefaults.standard.array(forKey: "place-" + info.id) as? [Double], place.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak v] in
                guard let self, let v else { return }
                let fit = v.scaleFactorForSizeToFit
                if fit > 0, abs(place[1] - 1) > 0.02 { v.scaleFactor = fit * place[1] }
                if let p = self.document.page(at: Int(place[0])) { v.go(to: p) }
            }
        }
        return v
    }()

    private var scrollView: UIScrollView? {
        func find(_ v: UIView) -> UIScrollView? {
            for s in v.subviews {
                if let sv = s as? UIScrollView, !(s is PKCanvasView) { return sv }
                if let f = find(s) { return f }
            }
            return nil
        }
        return find(view)
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        if let o = overlays[page] { return o }
        let o = PageOverlay(page: page, model: self)
        o.canvas.delegate = self
        if let d = saved[page], let drawing = try? PKDrawing(data: d) { o.canvas.drawing = drawing }
        o.items = items[page] ?? []
        overlays[page] = o
        o.configure()
        return o
    }

    var firstOverlay: PageOverlay? { document.page(at: 0).flatMap { overlays[$0] } }

    private func overlay(of canvas: PKCanvasView) -> PageOverlay? { canvas.superview as? PageOverlay }

    // MARK: tools

    /// The colour new text takes: the pen last used.
    var inkColor: String {
        if case .pen(let id) = tool, let p = Prefs.shared.pen(id) { return p.color }
        if case .pen(let id) = previous, let p = Prefs.shared.pen(id) { return p.color }
        return "#111111"
    }

    private func toolChanged(from old: Tool) {
        previous = old
        if case .pen(let id) = tool { UserDefaults.standard.set(id, forKey: "pen") }
        refreshTools()
    }

    /// The tool, a pen's settings, the eraser's size or "draw with a finger" changed.
    func refreshTools() {
        if case .pen(let id) = tool, Prefs.shared.pen(id) == nil { tool = .pen(Prefs.shared.pens[0].id); return }
        overlays.values.forEach { $0.configure() }
    }

    func back() { tool = previous }

    func selectionChanged(_ o: PageOverlay) {
        if o.hasSelection {
            if let s = selected, s !== o { s.clearSelection() }
            selected = o
        } else if selected === o { selected = nil }
        hasSelection = selected != nil
    }

    func recolourSelection(_ hex: String) { selected?.recolour(hex) }
    func deleteSelection() { selected?.deleteSelection() }

    // MARK: Apple Pencil: double-tap and squeeze do what Settings says

    private func pencil(_ key: String) {
        switch UserDefaults.standard.string(forKey: key) {
        case "eraser": tool = tool == .eraser ? previous : .eraser
        case "undo": undo()
        case "redo": redo()
        case "previous": back()
        case "lasso": tool = tool == .lasso ? previous : .lasso
        case "hand": tool = tool == .hand ? previous : .hand
        default: break
        }
    }

    nonisolated func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        Task { @MainActor in self.pencil("pencilTap") }
    }

    nonisolated func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        let ended = squeeze.phase == .ended
        Task { @MainActor in if ended { self.pencil("pencilSqueeze") } }
    }

    // MARK: the pen, watched: the hold that makes a shape, "page follows pen", Studio's pen path

    private var isDown = false
    private var anchor = CGPoint.zero
    private var lastMove: TimeInterval = 0
    private var lastTrace: TimeInterval = 0
    private var lastY: CGFloat = 0
    private var follow: Task<Void, Never>?

    private func penDown(_ t: UITouch) {
        isDown = true
        follow?.cancel()
        ghost.isHidden = true
        anchor = t.location(in: view)
        lastMove = t.timestamp
    }

    private func penMoved(_ t: UITouch) {
        let p = t.location(in: view)
        if hypot(p.x - anchor.x, p.y - anchor.y) > 4 {
            anchor = p
            lastMove = t.timestamp
        }
        lastY = p.y
        if t.type == .pencil, t.timestamp - lastTrace > 0.05 {
            lastTrace = t.timestamp
            Recording.shared.pen(at: t.location(in: nil), down: true)
        }
    }

    private func penUp() {
        isDown = false
        guard UserDefaults.standard.bool(forKey: "followPen"), case .pen(let id) = tool, Prefs.shared.pen(id)?.type != "laser" else { return }
        let y = lastY, h = view.bounds.height
        guard y > 0.75 * h else { return }
        follow = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)   // never between the letters of a word
            guard !Task.isCancelled, let self, !self.isDown, let sv = self.scrollView else { return }
            let most = max(sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom, sv.contentOffset.y)
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: min(sv.contentOffset.y + y - 0.4 * h, most)), animated: true)
        }
    }

    // The shadow of the hovering Pencil: it leans the way the pen leans, and pales as the pen rises.
    private let ghost: CAGradientLayer = {
        let g = CAGradientLayer()
        g.colors = [UIColor.black.withAlphaComponent(0.4).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        g.anchorPoint = CGPoint(x: 0, y: 0.5)
        g.cornerRadius = 7
        g.isHidden = true
        return g
    }()

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        let p = g.location(in: view)
        if g.state == .began || g.state == .changed { Recording.shared.pen(at: g.location(in: nil), down: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard g.state == .began || g.state == .changed, !isDown, UserDefaults.standard.bool(forKey: "penShadow"), g.altitudeAngle < .pi / 2 - 0.01 else {
            ghost.isHidden = true
            return
        }
        // ponytail: if the shadow points the wrong way on the device, flip the sign of the azimuth here
        ghost.isHidden = false
        ghost.bounds = CGRect(x: 0, y: 0, width: 50 + 170 * cos(g.altitudeAngle), height: 14)
        ghost.position = p
        ghost.transform = CATransform3DMakeRotation(g.azimuthAngle(in: view), 0, 0, 1)
        ghost.opacity = Float(0.55 * (1 - 0.6 * min(max(g.zOffset, 0), 1)))
    }

    // MARK: PKCanvasViewDelegate

    private weak var endedOn: PKCanvasView?
    private weak var changedOn: PKCanvasView?
    private var held = false

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        endedOn = nil
        changedOn = nil
        if let s = selected { s.clearSelection() }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if let o = overlay(of: canvasView) { dirty.insert(o.page) }
        scheduleSave()
        guard !quiet else { return }
        changedOn = canvasView
        finishStroke()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        if tool == .eraser {
            if UserDefaults.standard.bool(forKey: "autoErase") { back() }
            return
        }
        held = ProcessInfo.processInfo.systemUptime - lastMove >= 0.5
        endedOn = canvasView
        finishStroke()
    }

    /// Once a stroke is both lifted and in the drawing: a stroke held still at its end becomes the clean
    /// shape it was meant to be, and a glow pen's stroke gets its halo.
    private func finishStroke() {
        guard let c = endedOn, c === changedOn, let o = overlay(of: c), case .pen(let id) = tool, let pen = Prefs.shared.pen(id) else { return }
        endedOn = nil
        changedOn = nil
        let old = c.drawing
        var strokes = old.strokes
        guard var last = strokes.popLast() else { return }
        var changed = false
        if held {
            let pts = last.path.map { $0.location.applying(last.transform) }
            let widths = last.path.map { $0.size.width }.sorted()
            if let clean = Shapes.recognise(pts, min: 24 * Double(o.k)), !widths.isEmpty {
                last = EditorModel.stroke(clean, ink: last.ink, width: widths[widths.count / 2])
                changed = true
            }
        }
        if pen.type == "glow" {
            let halo = last.path.map {
                PKStrokePoint(location: $0.location, timeOffset: $0.timeOffset, size: CGSize(width: $0.size.width * 3.5, height: $0.size.height * 3.5),
                              opacity: $0.opacity, force: $0.force, azimuth: $0.azimuth, altitude: $0.altitude)
            }
            strokes.append(PKStroke(ink: PKInk(.marker, color: pen.uiColor.withAlphaComponent(0.3)),
                                    path: PKStrokePath(controlPoints: halo, creationDate: Date()), transform: last.transform, mask: nil))
            changed = true
        }
        guard changed else { return }
        strokes.append(last)
        registerRestore(o, drawing: old, items: o.items)
        quietly { c.drawing = PKDrawing(strokes: strokes) }
    }

    static func stroke(_ pts: [CGPoint], ink: PKInk, width: CGFloat) -> PKStroke {
        let cps = pts.enumerated().map {
            PKStrokePoint(location: $1, timeOffset: Double($0) * 0.005, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: cps, creationDate: Date()), transform: .identity, mask: nil)
    }

    // MARK: changes the app makes itself (lasso, shapes, text, pictures), and their undo

    /// Set a canvas's drawing without the stroke-finishing above looking at it.
    func quietly(_ work: () -> Void) {
        quiet = true
        work()
        quiet = false
    }

    private var undoer: UndoManager? { view.undoManager }
    func undo() { undoer?.undo() }
    func redo() { undoer?.redo() }

    /// Undo puts this drawing and these items back (and redo what was there before that).
    func registerRestore(_ o: PageOverlay, drawing: PKDrawing, items its: [Item]) {
        undoer?.registerUndo(withTarget: o) { [weak self] o in
            guard let self else { return }
            let d = o.canvas.drawing, i = o.items
            o.clearSelection()
            self.registerRestore(o, drawing: d, items: i)
            self.quietly { o.canvas.drawing = drawing }
            self.set(o, its)
        }
    }

    /// A new drawing and/or new items for a page, undoable.
    func change(_ o: PageOverlay, drawing: PKDrawing?, items its: [Item]) {
        registerRestore(o, drawing: o.canvas.drawing, items: o.items)
        if let drawing { quietly { o.canvas.drawing = drawing } }
        set(o, its)
    }

    private func set(_ o: PageOverlay, _ its: [Item]) {
        o.items = its
        items[o.page] = its.isEmpty ? nil : its
        itemsDirty = true
        scheduleSave()
    }

    /// A picture from Photos or the clipboard, put in the middle of what is on the screen.
    func addPicture(_ image: UIImage) {
        guard let page = view.currentPage, let o = overlays[page] else { return }
        let name = "img-\(UUID().uuidString.prefix(8)).jpg"
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 2000 / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.85) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard (try? data.write(to: folder.appendingPathComponent(name))) != nil else { return }
        let w = min(420, Double(size.width)), h = w * Double(size.height / max(size.width, 1))
        let mid = o.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
        let x = min(max(Double(mid.x / o.k) - w / 2, 0), Paper.width - w), y = max(Double(mid.y / o.k) - h / 2, 0)
        change(o, drawing: nil, items: o.items + [Item(kind: "image", x: x, y: y, w: w, h: h, file: name)])
        tool = .lasso
    }

    // MARK: zoom

    @objc private func scaleChanged() {
        let fit = view.scaleFactorForSizeToFit
        zoom = fit > 0 ? view.scaleFactor / fit : 1
        isFit = abs(zoom - 1) < 0.005
        magnet?.cancel()
        // Freenotes' band round fit-width: a pinch that ends inside it settles on fit-width.
        // ponytail: it settles after the pinch, where the web app's fitband.js skips the band while pinching.
        guard !isFit, zoom > 135.0 / 144, zoom < 155.0 / 144 else { return }
        magnet = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled, let self, self.scrollView?.isZooming != true else { return }
            self.fitWidth()
        }
    }
    private var magnet: Task<Void, Never>?

    @objc private func pageTurned() { pageIndex = currentIndex }

    func fitWidth() { UIView.animate(withDuration: 0.2) { self.view.scaleFactor = self.view.scaleFactorForSizeToFit } }
    func zoom(by f: CGFloat) {
        let fit = view.scaleFactorForSizeToFit
        view.scaleFactor = min(max(view.scaleFactor * f, fit * 0.4), fit * 8)
    }

    // MARK: saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { self?.saveNow() }
        }
    }

    private var eachPage: [PDFPage] { (0..<document.pageCount).compactMap { document.page(at: $0) } }

    func saveNow() {
        saveTask?.cancel()
        overlays.values.forEach { $0.endText() }
        UserDefaults.standard.set([Double(currentIndex), Double(zoom)], forKey: "place-" + info.id)
        guard structureDirty || itemsDirty || !dirty.isEmpty else { return }
        if structureDirty { store.writePDF(document, id: info.id) }
        for p in dirty {
            if let o = overlays[p] { saved[p] = o.canvas.drawing.strokes.isEmpty ? nil : o.canvas.drawing.dataRepresentation() }
        }
        if structureDirty || !dirty.isEmpty { store.writeDrawings(info.id, eachPage.map { saved[$0] ?? Data() }) }
        if structureDirty || itemsDirty { store.writeItems(info.id, eachPage.map { items[$0] ?? [] }) }
        structureDirty = false
        itemsDirty = false
        dirty.removeAll()
        store.touch(info.id)
    }

    func rename(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != info.name else { return }
        store.rename(info.id, to: n)
        info.name = n
    }

    // MARK: pages

    var currentIndex: Int {
        guard let p = view.currentPage else { return 0 }
        return max(0, document.index(for: p))
    }

    /// Add space: a blank page of the notebook's paper after this one.
    func addPage(after at: Int? = nil) {
        let at = at ?? currentIndex
        let size = document.page(at: at)?.bounds(for: .mediaBox).size ?? CGSize(width: Paper.width, height: info.paper.pageHeight)
        let page = PaperPDF.blankPage(paper: info.paper, size: size)
        document.insert(page, at: min(at + 1, document.pageCount))
        pagesChanged(go: page)
    }

    func deletePage(_ at: Int) {
        guard document.pageCount > 1, let p = document.page(at: at) else { return }
        document.removePage(at: at)
        forget(p)
        pagesChanged(go: document.page(at: min(at, document.pageCount - 1)))
    }

    private func forget(_ p: PDFPage) {
        overlays[p] = nil
        saved[p] = nil
        items[p] = nil
        dirty.remove(p)
    }

    func duplicatePage(_ at: Int) {
        guard let p = document.page(at: at), let copy = p.copy() as? PDFPage else { return }
        saved[copy] = drawing(for: p)?.dataRepresentation()
        items[copy] = (overlays[p]?.items ?? items[p])?.map { var n = $0; n.id = UUID().uuidString; return n }
        document.insert(copy, at: at + 1)
        pagesChanged(go: copy)
    }

    func movePage(from: Int, to: Int) {
        guard from != to, let p = document.page(at: from) else { return }
        document.removePage(at: from)
        document.insert(p, at: min(max(to, 0), document.pageCount))
        pagesChanged(go: p)
    }

    /// This page's own paper: another template or colour. What is written on it stays.
    func restyle(_ at: Int, template: String? = nil, color: String? = nil) {
        guard let old = document.page(at: at) else { return }
        var paper = info.paper
        if let color, color != paper.color { paper.line = color == "#111111" ? "#44444c" : paper.line }
        let page = PaperPDF.blankPage(paper: paper, size: old.bounds(for: .mediaBox).size, template: template, color: color)
        saved[page] = drawing(for: old)?.dataRepresentation()
        items[page] = overlays[old]?.items ?? items[old]
        document.removePage(at: at)
        forget(old)
        document.insert(page, at: at)
        pagesChanged(go: page)
    }

    /// Moving, copying or deleting pages clears undo (as in the web app).
    private func pagesChanged(go page: PDFPage?) {
        undoer?.removeAllActions()
        structureDirty = true
        itemsDirty = true
        pageCount = document.pageCount
        view.layoutDocumentView()
        if let page { view.go(to: page) }
        pageIndex = currentIndex
        saveNow()
    }

    func go(to index: Int) {
        if let p = document.page(at: index) { view.go(to: p) }
    }

    private func drawing(for p: PDFPage) -> PKDrawing? {
        if let o = overlays[p] { return o.canvas.drawing }
        if let d = saved[p] { return try? PKDrawing(data: d) }
        return nil
    }

    /// A page as it looks: paper, text and pictures, ink. `scale`: pixels for each of the page's points.
    private func paint(_ p: PDFPage, in rect: CGRect, _ c: CGContext, inkScale: CGFloat) {
        let box = p.bounds(for: .mediaBox)
        c.saveGState()
        c.translateBy(x: 0, y: rect.height)
        c.scaleBy(x: rect.width / box.width, y: -rect.height / box.height)
        p.draw(with: .mediaBox, to: c)
        c.restoreGState()
        for it in overlays[p]?.items ?? items[p] ?? [] { it.draw(k: rect.width / CGFloat(Paper.width), folder: folder) }
        if let d = drawing(for: p), !d.strokes.isEmpty {
            // the ink is in the overlay's points, which are the page's
            d.image(from: CGRect(origin: .zero, size: box.size), scale: inkScale).draw(in: rect)
        }
    }

    func thumbnail(_ index: Int, width: CGFloat) -> UIImage? {
        guard let p = document.page(at: index) else { return nil }
        let box = p.bounds(for: .mediaBox)
        let size = CGSize(width: width, height: width * box.height / max(box.width, 1))
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            paint(p, in: CGRect(origin: .zero, size: size), ctx.cgContext, inkScale: size.width / box.width)
        }
    }

    // MARK: export

    /// The notebook as one flat PDF: the pages with the text, pictures and ink drawn on them.
    func exportPDF() -> URL? {
        saveNow()
        guard let first = document.page(at: 0) else { return nil }
        let name = Recorder.fileSafe(info.name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.bounds(for: .mediaBox).size))
        do {
            try renderer.writePDF(to: url) { ctx in
                for p in eachPage {
                    let rect = CGRect(origin: .zero, size: p.bounds(for: .mediaBox).size)
                    ctx.beginPage(withBounds: rect, pageInfo: [:])
                    paint(p, in: rect, ctx.cgContext, inkScale: 3)
                }
            }
            return url
        } catch {
            return nil
        }
    }

    // MARK: the promo cover: EngiKode's title page in front of the note (the web app's cover.js, drawn once into a PDF page)

    func toggleCover() async {
        if hasCover {
            if document.pageCount > 1, let p = document.page(at: 0) {
                document.removePage(at: 0)
                forget(p)
            }
            hasCover = false
        } else {
            guard let fonts = Bundle.main.url(forResource: "cover-fonts", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
                  let cover = Bundle.main.url(forResource: "cover", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
                  let js = JSContext() else { return Notice.shared.say("The cover could not be made.") }
            js.evaluateScript(EditorModel.plainScript(fonts))
            js.evaluateScript(EditorModel.plainScript(cover))
            guard let html = js.evaluateScript("doc(false)")?.toString(), html.hasPrefix("<!doctype"),
                  let made = await HTMLRenderer.document(html: html, base: nil, height: 506),
                  let page = made.page(at: 0)?.copy() as? PDFPage else { return Notice.shared.say("The cover could not be made.") }
            document.insert(page, at: 0)
            hasCover = true
        }
        UserDefaults.standard.set(hasCover, forKey: "cover-" + info.id)
        pagesChanged(go: document.page(at: 0))
    }

    /// A web module as a plain script: its imports dropped and its exports made ordinary declarations.
    static func plainScript(_ module: String) -> String {
        module.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.hasPrefix("import ") { return "" }
            if line.hasPrefix("export ") { return String(line.dropFirst(7)) }
            return String(line)
        }.joined(separator: "\n")
    }
}
