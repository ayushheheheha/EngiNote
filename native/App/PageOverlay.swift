import PDFKit
import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A text box or a picture placed on a page. Places and sizes are in page units (a page is 900 across),
/// like the web app's items.
struct Item: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: String            // text, image
    var x: Double, y: Double, w: Double, h: Double
    var text = ""
    var size = 28.0             // the letters' size
    var color = "#111111"
    var file = ""               // a picture's file name, in the notebook's folder

    static let textWidth = 420.0

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    /// Drawn into the current UIKit context, `k` points for each page unit (export, thumbnails).
    func draw(k: CGFloat, folder: URL) {
        let r = CGRect(x: x * k, y: y * k, width: w * k, height: h * k)
        if kind == "image" {
            Item.picture(file, folder)?.draw(in: r)
        } else {
            (text as NSString).draw(in: r, withAttributes: [.font: UIFont.systemFont(ofSize: size * k), .foregroundColor: UIColor(hex: color)])
        }
    }

    private static let pictures = NSCache<NSString, UIImage>()
    static func picture(_ file: String, _ folder: URL) -> UIImage? {
        let url = folder.appendingPathComponent((file as NSString).lastPathComponent)
        if let hit = pictures.object(forKey: url.path as NSString) { return hit }
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        pictures.setObject(img, forKey: url.path as NSString)
        return img
    }
}

/// A touch handed to the tools that are not PencilKit's (laser, lasso, text): it begins the moment the tip
/// lands, so the page under it does not scroll.
final class ToolTouch: UIGestureRecognizer {
    private(set) var moved = false
    private var from = CGPoint.zero
    private weak var finger: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard finger == nil, let t = touches.first else { return }
        finger = t
        from = t.location(in: view)
        moved = false
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = finger, touches.contains(t) else { return }
        let p = t.location(in: view)
        if hypot(p.x - from.x, p.y - from.y) > 10 { moved = true }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = finger, touches.contains(t) { state = .ended }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = finger, touches.contains(t) { state = .cancelled }
    }

    override func reset() { finger = nil }
}

/// Watches the pen without ever taking a touch: when it lands, where it goes, when it lifts. That is what the
/// hold at the end of a stroke (shapes), "page follows pen" and Studio's pen path are worked out from.
final class PenWatch: UIGestureRecognizer {
    var down: ((UITouch) -> Void)?
    var move: ((UITouch) -> Void)?
    var up: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { touches.first.map { down?($0) } }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { touches.first.map { move?($0) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { up?(); state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { up?(); state = .failed }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// What lies over one page: the text boxes and pictures, the PencilKit canvas, and the marks of the
/// tools (the laser's light, the lasso's line and box).
final class PageOverlay: UIView, UITextViewDelegate {
    let canvas = PKCanvasView()
    let page: PDFPage
    unowned let model: EditorModel
    private let itemLayer = UIView()
    private let fx = UIView()
    private var touch: ToolTouch!

    var items: [Item] = [] { didSet { if items != oldValue { renderItems() } } }
    var k: CGFloat { max(bounds.width, 1) / CGFloat(Paper.width) }

    init(page: PDFPage, model: EditorModel) {
        self.page = page
        self.model = model
        super.init(frame: .zero)
        backgroundColor = .clear
        itemLayer.isUserInteractionEnabled = false
        fx.isUserInteractionEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false   // fingers scroll and zoom the page, not the canvas
        for v in [itemLayer, canvas, fx] {
            v.frame = bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(v)
        }
        for l in [lassoLine, boxLine, handle] { fx.layer.addSublayer(l) }
        lassoLine.fillColor = nil
        lassoLine.strokeColor = UIColor.systemBlue.cgColor
        lassoLine.lineDashPattern = [6, 4]
        boxLine.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        boxLine.strokeColor = UIColor.systemBlue.cgColor
        boxLine.lineDashPattern = [6, 4]
        handle.fillColor = UIColor.systemBlue.cgColor
        touch = ToolTouch(target: self, action: #selector(touched(_:)))
        addGestureRecognizer(touch)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var laidOut: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != laidOut {   // the letters and the pen's width follow the page's size
            laidOut = bounds.width
            renderItems()
            configure()
        }
    }

    /// Set up for the tool in use: who takes the pen's touches, and what PencilKit draws with.
    func configure() {
        let d = UserDefaults.standard
        let fingers = d.bool(forKey: "fingerDraws")
        var ink = false, own = false
        switch model.tool {
        case .pen(let id):
            if let pen = Prefs.shared.pen(id), pen.type != "laser" {
                canvas.tool = pen.tool(k: k)
                ink = true
            } else { own = true }
        case .eraser:
            let size = CGFloat(d.double(forKey: "eraserSize")) * k * 2
            canvas.tool = d.bool(forKey: "eraserPixels") ? PKEraserTool(.bitmap, width: max(size, 2)) : PKEraserTool(.vector)
            ink = true
        case .hand: break
        case .text, .lasso: own = true
        }
        canvas.isUserInteractionEnabled = ink
        canvas.drawingPolicy = fingers ? .anyInput : .pencilOnly
        touch.isEnabled = own
        let kinds: [UITouch.TouchType] = fingers ? [.pencil, .direct] : [.pencil]
        touch.allowedTouchTypes = kinds.map { NSNumber(value: $0.rawValue) }
        if model.tool != .text { endText() }
        if model.tool != .lasso { clearSelection() }
    }

    @objc private func touched(_ g: ToolTouch) {
        let p = g.location(in: self)
        switch model.tool {
        case .pen(let id): laser(g, p, Prefs.shared.pen(id))
        case .text: if g.state == .ended, !g.moved { textAt(p) }
        case .lasso: lasso(g, p)
        default: break
        }
    }

    // MARK: text boxes and pictures

    private var shown: [UIView] = []
    private func renderItems() {
        shown.forEach { $0.removeFromSuperview() }
        shown = items.filter { $0.id != typing?.item.id }.map { it in
            let r = CGRect(x: it.x * k, y: it.y * k, width: it.w * k, height: it.h * k)
            if it.kind == "image" {
                let v = UIImageView(frame: r)
                v.image = Item.picture(it.file, model.folder)
                return v
            }
            let l = UILabel(frame: r)
            l.numberOfLines = 0
            l.font = .systemFont(ofSize: it.size * k)
            l.textColor = UIColor(hex: it.color)
            l.text = it.text
            return l
        }
        shown.forEach { itemLayer.addSubview($0) }
    }

    private var typing: (item: Item, view: UITextView)?

    /// A tap with the text tool: on a text box it edits it, anywhere else it starts a new one there.
    private func textAt(_ p: CGPoint) {
        let u = CGPoint(x: p.x / k, y: p.y / k)
        endText()
        let it = items.last { $0.kind == "text" && $0.rect.insetBy(dx: -6, dy: -6).contains(u) }
            ?? Item(kind: "text", x: u.x, y: u.y - UserDefaults.standard.double(forKey: "textSize") / 2, w: Item.textWidth, h: 0,
                    size: UserDefaults.standard.double(forKey: "textSize"), color: model.inkColor)
        let tv = UITextView(frame: CGRect(x: it.x * k, y: it.y * k, width: Item.textWidth * k, height: max(it.h, it.size * 1.4) * k))
        tv.font = .systemFont(ofSize: it.size * k)
        tv.textColor = UIColor(hex: it.color)
        tv.backgroundColor = .clear
        tv.text = it.text
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.5).cgColor
        tv.layer.borderWidth = 1
        tv.delegate = self
        addSubview(tv)
        typing = (it, tv)
        renderItems()
        tv.becomeFirstResponder()
    }

    func textViewDidChange(_ tv: UITextView) {
        tv.frame.size.height = max(tv.sizeThatFits(CGSize(width: tv.bounds.width, height: .greatestFiniteMagnitude)).height, tv.frame.height)
    }

    func textViewDidEndEditing(_ tv: UITextView) { endText() }

    /// What was typed becomes the text box (or, if nothing is left, the box goes).
    func endText() {
        guard let (old, tv) = typing else { return }
        typing = nil
        var next = items.filter { $0.id != old.id }
        let text = tv.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            var it = old
            it.text = text
            let fit = tv.sizeThatFits(CGSize(width: Item.textWidth * k, height: .greatestFiniteMagnitude))
            it.w = min(Item.textWidth, Double(fit.width / k) + 2)
            it.h = Double(fit.height / k)
            next.append(it)
        }
        tv.delegate = nil
        tv.resignFirstResponder()
        tv.removeFromSuperview()
        if next != items { model.change(self, drawing: nil, items: next) } else { renderItems() }
    }

    // MARK: the laser: a line of light that fades, and is never part of the note

    private var beam: CAShapeLayer?
    private var beamPath = UIBezierPath()

    private func laser(_ g: ToolTouch, _ p: CGPoint, _ pen: Pen?) {
        switch g.state {
        case .began:
            let l = CAShapeLayer()
            let c = (pen?.uiColor ?? .red).cgColor
            l.fillColor = nil
            l.strokeColor = c
            l.lineWidth = CGFloat(pen?.size ?? 4) * k * 1.2
            l.lineCap = .round
            l.lineJoin = .round
            l.shadowColor = c
            l.shadowOpacity = 1
            l.shadowRadius = 6 * k
            l.shadowOffset = .zero
            fx.layer.addSublayer(l)
            beam = l
            beamPath = UIBezierPath()
            beamPath.move(to: p)
            beamPath.addLine(to: p)
            l.path = beamPath.cgPath
        case .changed:
            beamPath.addLine(to: p)
            beam?.path = beamPath.cgPath
        default:
            guard let l = beam else { return }
            beam = nil
            CATransaction.begin()
            CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 1.1
            l.opacity = 0
            l.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    // MARK: the lasso: circle some ink, text or pictures (or tap one), then move, resize, recolour or delete it

    private let lassoLine = CAShapeLayer(), boxLine = CAShapeLayer(), handle = CAShapeLayer()
    private var lassoPath = UIBezierPath()
    private(set) var selStrokes: [Int] = []
    private(set) var selItems: [String] = []
    private var selBox = CGRect.null
    private enum Drag { case draw, move, resize }
    private var drag = Drag.draw
    private var dragFrom = CGPoint.zero
    private var base: (drawing: PKDrawing, items: [Item], box: CGRect)?

    var hasSelection: Bool { !selStrokes.isEmpty || !selItems.isEmpty }
    private var handleRect: CGRect { CGRect(x: selBox.maxX - 16 * k, y: selBox.maxY - 16 * k, width: 32 * k, height: 32 * k) }

    private func lasso(_ g: ToolTouch, _ p: CGPoint) {
        switch g.state {
        case .began:
            dragFrom = p
            if hasSelection, handleRect.contains(p) { drag = .resize } else if hasSelection, selBox.insetBy(dx: -8 * k, dy: -8 * k).contains(p) { drag = .move } else {
                clearSelection()
                drag = .draw
                lassoPath = UIBezierPath()
                lassoPath.move(to: p)
            }
            if drag != .draw { base = (canvas.drawing, items, selBox) }
        case .changed:
            if drag == .draw {
                lassoPath.addLine(to: p)
                lassoLine.lineWidth = 1.5 * k
                lassoLine.path = lassoPath.cgPath
            } else { apply(transform(to: p)) }
        case .ended:
            if drag == .draw {
                lassoLine.path = nil
                if g.moved {
                    lassoPath.close()
                    select(in: lassoPath)
                } else { pick(at: p) }
            } else if let b = base {
                apply(transform(to: p))
                model.registerRestore(self, drawing: b.drawing, items: b.items)
                base = nil
            }
        default:
            lassoLine.path = nil
            if drag != .draw, let b = base {
                model.quietly { canvas.drawing = b.drawing }
                items = b.items
                selBox = b.box
                drawBox()
            }
            base = nil
        }
    }

    private func transform(to p: CGPoint) -> CGAffineTransform {
        guard let b = base else { return .identity }
        if drag == .move { return CGAffineTransform(translationX: p.x - dragFrom.x, y: p.y - dragFrom.y) }
        let o = b.box.origin
        let s = max(0.1, hypot(p.x - o.x, p.y - o.y) / max(hypot(dragFrom.x - o.x, dragFrom.y - o.y), 1))
        return CGAffineTransform(translationX: -o.x, y: -o.y).concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: o.x, y: o.y))
    }

    private func apply(_ t: CGAffineTransform) {
        guard let b = base else { return }
        var strokes = b.drawing.strokes
        for i in selStrokes where i < strokes.count { strokes[i].transform = strokes[i].transform.concatenating(t) }
        model.quietly { canvas.drawing = PKDrawing(strokes: strokes) }
        items = b.items.map { it in
            guard selItems.contains(it.id) else { return it }
            let r = CGRect(x: it.x * k, y: it.y * k, width: it.w * k, height: it.h * k).applying(t)
            var n = it
            n.x = r.minX / k; n.y = r.minY / k; n.w = r.width / k; n.h = r.height / k
            n.size = it.size * Double(t.a)
            return n
        }
        selBox = b.box.applying(t)
        drawBox()
    }

    private func points(of s: PKStroke) -> [CGPoint] {
        s.path.interpolatedPoints(by: .distance(10)).map { $0.location.applying(s.transform) }
    }

    func select(in path: UIBezierPath) {
        let strokes = canvas.drawing.strokes
        selStrokes = strokes.indices.filter { i in
            let pts = points(of: strokes[i])
            return !pts.isEmpty && pts.filter { path.contains($0) }.count * 2 >= pts.count
        }
        selItems = items.filter { path.contains(CGPoint(x: $0.rect.midX * k, y: $0.rect.midY * k)) }.map(\.id)
        settle()
    }

    private func pick(at p: CGPoint) {
        let strokes = canvas.drawing.strokes
        if let it = items.last(where: { $0.rect.contains(CGPoint(x: p.x / k, y: p.y / k)) }) {
            selItems = [it.id]
        } else if let i = strokes.indices.last(where: { i in
            strokes[i].renderBounds.insetBy(dx: -10 * k, dy: -10 * k).contains(p) && points(of: strokes[i]).contains { hypot($0.x - p.x, $0.y - p.y) < 14 * k }
        }) {
            selStrokes = [i]
        }
        settle()
    }

    /// The box round what is chosen, and the news to the tray (which shows the colours and the bin).
    private func settle() {
        let strokes = canvas.drawing.strokes
        var box = CGRect.null
        for i in selStrokes where i < strokes.count { box = box.union(strokes[i].renderBounds) }
        for it in items where selItems.contains(it.id) { box = box.union(CGRect(x: it.x * k, y: it.y * k, width: it.w * k, height: it.h * k)) }
        selBox = box
        drawBox()
        model.selectionChanged(self)
    }

    private func drawBox() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hasSelection, !selBox.isNull {
            boxLine.lineWidth = 1.5 * k
            boxLine.path = UIBezierPath(rect: selBox.insetBy(dx: -6 * k, dy: -6 * k)).cgPath
            handle.path = UIBezierPath(ovalIn: CGRect(x: selBox.maxX - 1 * k, y: selBox.maxY - 1 * k, width: 14 * k, height: 14 * k)).cgPath
        } else {
            boxLine.path = nil
            handle.path = nil
        }
        CATransaction.commit()
    }

    func clearSelection() {
        guard hasSelection else { return }
        selStrokes = []
        selItems = []
        selBox = .null
        drawBox()
        model.selectionChanged(self)
    }

    /// A new colour for the chosen ink and text.
    func recolour(_ hex: String) {
        var strokes = canvas.drawing.strokes
        for i in selStrokes where i < strokes.count {
            let old = strokes[i].ink
            strokes[i].ink = PKInk(old.inkType, color: UIColor(hex: hex).withAlphaComponent(old.color.cgColor.alpha))
        }
        let next = items.map { it -> Item in
            var n = it
            if selItems.contains(it.id), it.kind == "text" { n.color = hex }
            return n
        }
        model.change(self, drawing: PKDrawing(strokes: strokes), items: next)
    }

    func deleteSelection() {
        let gone = Set(selStrokes)
        let strokes = canvas.drawing.strokes.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
        let next = items.filter { !selItems.contains($0.id) }
        clearSelection()
        model.change(self, drawing: PKDrawing(strokes: strokes), items: next)
    }
}
