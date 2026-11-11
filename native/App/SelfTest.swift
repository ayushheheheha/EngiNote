import PencilKit
import SwiftUI

/// For the simulator check (a simulator cannot be tapped): launch flags that put things on the screen,
/// so a picture of it shows whether they work. Nothing here runs without a -demo flag.
enum SelfTest {
    static func has(_ flag: String) -> Bool { CommandLine.arguments.contains(flag) }

    @MainActor
    static func run(_ work: Workspace, _ chrome: Chrome) async {
        guard CommandLine.arguments.contains(where: { $0.hasPrefix("-demo") }) else { return }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if has("-demo-library") { work.toLibrary(); return }
        guard let model = work.front else { return }
        if has("-demo-ink") { model.demoInk() }
        if has("-demo-panes") {
            chrome.calc = true
            chrome.pages = true
            model.addPage()
            model.go(to: 0)
        }
        if has("-demo-wide") {
            chrome.setWide(true)
            Recording.shared.asking = true
        }
        if has("-demo-full") { chrome.full = true }
        if has("-demo-cover") { await model.toggleCover() }
    }
}

extension EditorModel {
    /// Handwriting-like strokes with each kind of pen, a rough circle and a rough line put through the shape
    /// recogniser, a text box; then the lasso takes the first strokes.
    func demoInk() {
        guard let o = firstOverlay else { return Notice.shared.say("Self test: no page overlay") }
        let k = o.k
        var strokes: [PKStroke] = []
        func wave(_ y: CGFloat, _ pen: Pen) {
            let pts = (0...60).map { i in CGPoint(x: (80 + CGFloat(i) * 9) * k, y: (y + 14 * sin(CGFloat(i) / 3)) * k) }
            let tool = pen.tool(k: k)
            strokes.append(EditorModel.stroke(pts, ink: tool.ink, width: tool.width))
        }
        for (i, pen) in Prefs.shared.pens.enumerated() where pen.type != "laser" { wave(120 + CGFloat(i) * 60, pen) }
        let rough = (0...40).map { i -> CGPoint in
            let a = CGFloat(i) / 40 * 2 * .pi
            return CGPoint(x: (300 + (110 + 5 * sin(a * 7)) * cos(a)) * k, y: (640 + (80 + 4 * cos(a * 5)) * sin(a)) * k)
        }
        let ink = PKInk(.pen, color: .systemBlue)
        if let clean = Shapes.recognise(rough, min: 24 * Double(k)) { strokes.append(EditorModel.stroke(clean, ink: ink, width: 4 * k)) } else {
            Notice.shared.say("Self test: the circle was NOT recognised")
            strokes.append(EditorModel.stroke(rough, ink: ink, width: 4 * k))
        }
        let line = (0...30).map { i in CGPoint(x: (480 + CGFloat(i) * 10) * k, y: (640 + CGFloat(i % 3)) * k) }
        if let clean = Shapes.recognise(line, min: 24 * Double(k)) { strokes.append(EditorModel.stroke(clean, ink: PKInk(.pen, color: .systemRed), width: 4 * k)) }
        change(o, drawing: PKDrawing(strokes: strokes), items: [Item(kind: "text", x: 480, y: 700, w: 300, h: 40, text: "Text box: y(t) = x(t) * h(t)", size: 28, color: "#1c7ed6")])
        tool = .lasso
        o.select(in: UIBezierPath(rect: CGRect(x: 60 * k, y: 90 * k, width: 700 * k, height: 110 * k)))
    }
}
