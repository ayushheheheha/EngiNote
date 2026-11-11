import PencilKit
import SwiftUI

/// One of the user's pens in the tray: its kind, colour, thickness and opacity (the web app's pens, same fields).
struct Pen: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var type: String            // pen, flow, glow, highlighter, laser
    var color: String           // #rrggbb
    var size: Double            // 1...12
    var opacity: Double         // 0.1...1

    static let types = ["pen", "flow", "glow", "highlighter", "laser"]
    static let names = ["pen": "Pen", "flow": "Flow pen", "glow": "Glow pen", "highlighter": "Highlighter", "laser": "Laser"]
    static let most = 12

    init(type: String, color: String) {
        self.type = type
        self.color = color
        size = type == "pen" ? 3 : 4
        opacity = type == "highlighter" ? 0.35 : 1
    }

    var name: String { Pen.names[type] ?? "Pen" }
    var uiColor: UIColor { UIColor(hex: color) }

    /// The PencilKit tool this pen draws with. `k`: page units to the canvas's points (a page is 900 units wide).
    func tool(k: CGFloat) -> PKInkingTool {
        let ink: PKInkingTool.InkType = type == "highlighter" ? .marker : type == "pen" ? .monoline : .pen
        let wanted = CGFloat(size) * k * (type == "highlighter" ? 5 : type == "pen" ? 1 : 1.6)
        let range = ink.validWidthRange
        return PKInkingTool(ink, color: uiColor.withAlphaComponent(CGFloat(opacity)), width: min(max(wanted, range.lowerBound), range.upperBound))
    }
}

/// What is remembered between launches: the pens, and the switches of Settings (those live in UserDefaults
/// under the names in `defaults`, and the views read them with @AppStorage).
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()

    static let defaults: [String: Any] = [
        "eraserSize": 8.0, "autoErase": false, "textSize": 28.0, "fingerDraws": false,
        "penShadow": true, "pencilTap": "eraser", "pencilSqueeze": "undo", "followPen": true, "noteTabs": true,
        "lecCam": false, "lecFull": false, "precheck": true,
        "recCount": true, "recMic": true, "recEnhance": false, "recWrap": false, "recQuality": "standard",
        "theme": "", "sort": "edited",
    ]
    static let pencilActions: [(String, String)] = [
        ("eraser", "Switch to the eraser"), ("undo", "Undo"), ("redo", "Redo"), ("previous", "Go back to the last tool"),
        ("lasso", "Lasso"), ("hand", "Hand"), ("none", "Nothing"),
    ]
    static let colors = ["#111111", "#ffffff", "#e03131", "#ff1744", "#1c7ed6", "#2f9e44", "#f08c00", "#ffea00", "#7048e8"]

    @Published var pens: [Pen] { didSet { save() } }
    @Published var recent: [String] { didSet { UserDefaults.standard.set(recent, forKey: "recentColors") } }

    private init() {
        UserDefaults.standard.register(defaults: Prefs.defaults)
        let first = [("pen", "#111111"), ("pen", "#ffffff"), ("pen", "#ff1744"), ("flow", "#1c7ed6"), ("glow", "#ffea00"), ("highlighter", "#ffea00")]
        var list: [Pen] = []
        if let d = UserDefaults.standard.data(forKey: "pens"), let saved = try? JSONDecoder().decode([Pen].self, from: d) {
            list = saved.filter { Pen.types.contains($0.type) }
        }
        pens = list.isEmpty ? first.map { Pen(type: $0.0, color: $0.1) } : Array(list.prefix(Pen.most))
        recent = UserDefaults.standard.stringArray(forKey: "recentColors") ?? []
    }

    private func save() {
        if let d = try? JSONEncoder().encode(pens) { UserDefaults.standard.set(d, forKey: "pens") }
    }

    func pen(_ id: String) -> Pen? { pens.first { $0.id == id } }

    func update(_ id: String, _ change: (inout Pen) -> Void) {
        guard let i = pens.firstIndex(where: { $0.id == id }) else { return }
        change(&pens[i])
    }

    /// A colour chosen with the colour picker comes back as a swatch.
    func remember(_ hex: String) {
        guard !Prefs.colors.contains(hex) else { return }
        recent = Array(([hex] + recent.filter { $0 != hex }).prefix(5))
    }
}

extension UIColor {
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
    }
}

/// A short message at the foot of the screen (the web app's #message).
@MainActor
final class Notice: ObservableObject {
    static let shared = Notice()
    @Published var text: String?
    private var timer: Timer?

    func say(_ s: String) {
        text = s
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.text = nil }
        }
    }
}

extension UIApplication {
    /// The view controller in front, to present a share sheet, the video editor or Studio from.
    static var top: UIViewController? {
        let scene = shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.keyWindow?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }

    static var window: UIWindow? {
        shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    static func share(_ files: [URL]) {
        guard let top, !files.isEmpty else { return }
        let sheet = UIActivityViewController(activityItems: files, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 40, width: 1, height: 1)
        top.present(sheet, animated: true)
    }
}
