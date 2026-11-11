import PhotosUI
import SwiftUI

// MARK: the look: glass capsules, chips, round icon buttons

extension View {
    /// iPadOS 26's Liquid Glass where there is one, a blurred pane before that.
    func glass() -> some View { glass(Capsule()) }

    @ViewBuilder func glass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape).overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
    }
}

/// A word in a capsule that is on or off (16:9, F, Mic, Auto…).
struct Chip: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12).frame(minWidth: 36, minHeight: 34)
            .foregroundStyle(on ? Color.white : .primary)
            .background(on ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08), in: Capsule())
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 40)
                .background(on ? Color.accentColor.opacity(0.3) : .clear, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

// MARK: a pen, as it stands in the tray (the web app's penPicture: barrel, metal, a tip in the pen's colour)

struct PenPicture: View {
    let pen: Pen

    var body: some View {
        Canvas { g, size in
            let s = size.width / 24
            g.scaleBy(x: s, y: s)
            let c = Color(uiColor: pen.uiColor)
            let wide = pen.type == "highlighter"
            let x: CGFloat = wide ? 4.5 : 6, w: CGFloat = wide ? 15 : 12
            func across(_ colors: [Color]) -> GraphicsContext.Shading {
                .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + w, y: 0))
            }
            let metal = across([Color(white: 0.5), Color(white: 0.96), Color(white: 0.82), Color(white: 0.58), Color(white: 0.42)])
            let barrel = across([Color(white: 0.11), Color(white: 0.36), Color(white: 0.5), Color(white: 0.29), Color(white: 0.09)])
            let shade = across([.black.opacity(0.22), .white.opacity(0.42), .white.opacity(0), .black.opacity(0.34)])
            func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
                var p = Path()
                p.addLines(pts.map { CGPoint(x: $0.0, y: $0.1) })
                p.closeSubpath()
                return p
            }
            func coloured(_ p: Path) { g.fill(p, with: .color(c)); g.fill(p, with: shade) }
            let cone = poly([(12, 2.6), (17, 18), (7, 18)])
            switch pen.type {
            case "flow":
                var nib = Path()
                nib.move(to: CGPoint(x: 12, y: 0.6))
                nib.addCurve(to: CGPoint(x: 16.6, y: 18), control1: CGPoint(x: 14.9, y: 5.1), control2: CGPoint(x: 17, y: 10.5))
                nib.addLine(to: CGPoint(x: 7.4, y: 18))
                nib.addCurve(to: CGPoint(x: 12, y: 0.6), control1: CGPoint(x: 7, y: 10.5), control2: CGPoint(x: 9.1, y: 5.1))
                g.fill(nib, with: metal)
                var slit = Path()
                slit.move(to: CGPoint(x: 12, y: 4.4))
                slit.addLine(to: CGPoint(x: 12, y: 13))
                g.stroke(slit, with: .color(.black.opacity(0.6)), lineWidth: 0.6)
                g.fill(Path(ellipseIn: CGRect(x: 11.1, y: 12.9, width: 1.8, height: 1.8)), with: .color(.black.opacity(0.6)))
            case "glow":
                g.drawLayer { l in
                    l.addFilter(.shadow(color: c, radius: 3))
                    l.fill(cone, with: .color(c))
                }
                var spark = Path()
                for (a, b) in [((4.2, 3.4), (4.2, 7.4)), ((2.2, 5.4), (6.2, 5.4)), ((20.4, 8.6), (20.4, 11.6)), ((18.9, 10.1), (21.9, 10.1))] {
                    spark.move(to: CGPoint(x: a.0, y: a.1))
                    spark.addLine(to: CGPoint(x: b.0, y: b.1))
                }
                g.stroke(spark, with: .color(c), lineWidth: 1)
            case "highlighter":
                coloured(poly([(7, 18), (7, 8.4), (17, 3.4), (17, 18)]))
            case "laser":
                g.fill(poly([(7.6, 18), (7.6, 11.6), (9.5, 8.8), (14.5, 8.8), (16.4, 11.6), (16.4, 18)]), with: metal)
                g.drawLayer { l in
                    l.addFilter(.shadow(color: c, radius: 3))
                    l.fill(Path(ellipseIn: CGRect(x: 9.3, y: 1.3, width: 5.4, height: 5.4)), with: .color(c))
                }
            default:
                coloured(cone)
                g.fill(poly([(12, 0.8), (13.3, 5.4), (10.7, 5.4)]), with: metal)
            }
            let flow = pen.type == "flow"
            if flow { coloured(Path(CGRect(x: x, y: 18, width: w, height: 4.4))) } else { g.fill(Path(CGRect(x: x, y: 18, width: w, height: 3.6)), with: metal) }
            g.fill(Path(roundedRect: CGRect(x: x, y: 21.6, width: w, height: 44), cornerRadius: 2), with: barrel)
            if flow { g.fill(Path(CGRect(x: x, y: 24.6, width: w, height: 1.4)), with: metal) } else { coloured(Path(CGRect(x: x, y: 25.4, width: w, height: 3.4))) }
        }
        .frame(width: 27, height: 72)
    }
}

// MARK: the tray

/// What is on the screen besides the note: which bars and panes are showing.
@MainActor
final class Chrome: ObservableObject {
    @Published var full = false       // the tools as a rail down the side, the note the whole height
    @Published var wide = false       // lecture mode: the app in a 16:9 window
    @Published var toolsOff = false   // the tools put away
    @Published var pages = false
    @Published var calc = false
    @Published var browser = false
    var lectureFull = false, lectureCam = false   // what lecture mode switched on itself, to undo with it

    func setWide(_ on: Bool) {
        let d = UserDefaults.standard, rec = Recording.shared
        wide = on
        rec.wide = on
        if on {
            if d.bool(forKey: "lecFull"), !full { full = true; lectureFull = true }
            if d.bool(forKey: "lecCam"), !rec.cameraOn { rec.setCamera(true); lectureCam = true }
        } else {
            if lectureFull { full = false }
            if lectureCam { rec.setCamera(false) }
            lectureFull = false
            lectureCam = false
        }
    }
}

/// The tools: the pens, then eraser, hand, text, picture, lasso, calculator, browser, finger; undo and redo; the view's buttons.
/// One line that slides sideways along the top, or (full screen) a rail down the side.
struct Tray: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var chrome: Chrome
    let vertical: Bool
    @ObservedObject private var prefs = Prefs.shared
    @AppStorage("fingerDraws") private var fingers = false
    @AppStorage("autoErase") private var autoErase = false
    @State private var panel: String?        // the pen whose settings are open
    @State private var eraserPanel = false, textPanel = false, settings = false
    @State private var photos = false
    @State private var photo: PhotosPickerItem?
    @State private var busy = false

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
            layout { tools }.padding(vertical ? .vertical : .horizontal, 8)
        }
        .scrollBounceBehavior(.basedOnSize, axes: vertical ? .vertical : .horizontal)
        .tint(.primary)
        .photosPicker(isPresented: $photos, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { model.addPicture(img) }
            }
        }
        .onChange(of: fingers) { _, _ in model.refreshTools() }
    }

    private var sep: some View {
        Rectangle().fill(Color.primary.opacity(0.2)).frame(width: vertical ? 22 : 1, height: vertical ? 1 : 22).padding(4)
    }

    @ViewBuilder private var tools: some View {
        if vertical {
            IconButton(symbol: "arrow.down.right.and.arrow.up.left", label: "Leave full screen") { chrome.full = false; chrome.lectureFull = false }
            sep
        }
        ForEach(prefs.pens) { pen in penButton(pen) }
        if prefs.pens.count < Pen.max {
            Menu {
                ForEach(Pen.types, id: \.self) { type in
                    Button(Pen.names[type] ?? type) {
                        let p = Pen(type: type, color: ["highlighter": "#ffea00", "laser": "#ff1744"][type] ?? model.inkColor)
                        prefs.pens.append(p)
                        model.tool = .pen(p.id)
                        panel = p.id
                    }
                }
            } label: { Image(systemName: "plus").font(.system(size: 18, weight: .medium)).frame(width: 40, height: 40) }
            .accessibilityLabel("Add a pen")
        }
        sep
        IconButton(symbol: "eraser", label: "Eraser. Tap again to set its size", on: model.tool == .eraser) {
            if model.tool == .eraser { eraserPanel = true } else { model.tool = .eraser }
        }
        .popover(isPresented: $eraserPanel) { EraserPanel(model: model) }
        if model.tool == .eraser {
            Button("Auto") { autoErase.toggle() }.buttonStyle(Chip(on: autoErase))
                .accessibilityLabel("Go back to the pen after erasing")
        }
        IconButton(symbol: "hand.raised", label: "Hand", on: model.tool == .hand) { model.tool = .hand }
        IconButton(symbol: "textformat", label: "Text: tap the page and type. Tap again to set its size", on: model.tool == .text) {
            if model.tool == .text { textPanel = true } else { model.tool = .text }
        }
        .popover(isPresented: $textPanel) { TextPanel() }
        Menu {
            Button { photos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
            Button {
                if let img = UIPasteboard.general.image { model.addPicture(img) } else { Notice.shared.say("There is no picture on the clipboard. Copy one first.") }
            } label: { Label("Paste picture", systemImage: "doc.on.clipboard") }
        } label: { Image(systemName: "photo").font(.system(size: 18, weight: .medium)).frame(width: 40, height: 40) }
        .accessibilityLabel("Add a picture")
        IconButton(symbol: "lasso", label: "Lasso: circle some ink to move, resize, recolour or delete it", on: model.tool == .lasso) { model.tool = .lasso }
        IconButton(symbol: "function", label: "Calculator", on: chrome.calc) { chrome.calc.toggle() }
        IconButton(symbol: "globe", label: "Browser", on: chrome.browser) { chrome.browser.toggle() }
        Button("F") { fingers.toggle() }.buttonStyle(Chip(on: fingers)).accessibilityLabel("Draw with a finger")
        sep
        IconButton(symbol: "arrow.uturn.backward", label: "Undo") { model.undo() }.keyboardShortcut("z", modifiers: .command)
        IconButton(symbol: "arrow.uturn.forward", label: "Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        sep
        if !vertical {
            IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Full screen") { chrome.full = true }
        }
        Button("16:9") { chrome.setWide(!chrome.wide) }.buttonStyle(Chip(on: chrome.wide)).accessibilityLabel("Lecture mode, 16 by 9 window")
        IconButton(symbol: "plus.rectangle.portrait", label: "Add space: a blank page after this one") { model.addPage() }
        IconButton(symbol: "rectangle.and.text.magnifyingglass", label: "Promo cover", on: model.hasCover) {
            guard !busy else { return }
            busy = true
            Task { await model.toggleCover(); busy = false }
        }
        IconButton(symbol: "square.on.square", label: "Pages", on: chrome.pages) { withAnimation(.spring(duration: 0.3)) { chrome.pages.toggle() } }
        IconButton(symbol: "square.and.arrow.up", label: "Export as PDF") {
            if let url = model.exportPDF() { UIApplication.share([url]) } else { Notice.shared.say("The PDF could not be made.") }
        }
        IconButton(symbol: "slider.horizontal.3", label: "Settings", on: settings) { settings = true }
            .popover(isPresented: $settings) { SettingsPanel() }
    }

    private func penButton(_ pen: Pen) -> some View {
        let on = model.tool == .pen(pen.id)
        return Button {
            if on { panel = pen.id } else { model.tool = .pen(pen.id) }
        } label: {
            PenPicture(pen: pen)
                .offset(y: on ? 3 : 13)
                .frame(width: 36, height: 44, alignment: .top)
                .clipped()
                .background(on ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .animation(.spring(duration: 0.3, bounce: 0.35), value: on)
        }
        .accessibilityLabel("\(pen.name). Tap again for its settings")
        .popover(isPresented: Binding(get: { panel == pen.id }, set: { if !$0 { panel = nil } })) {
            PenPanel(id: pen.id, model: model) { panel = nil }
        }
    }
}

/// The settings of the pen in use: thickness, opacity, colour; and the bin that removes it from the tray.
struct PenPanel: View {
    let id: String
    @ObservedObject var model: EditorModel
    let close: () -> Void
    @ObservedObject private var prefs = Prefs.shared
    @State private var custom = Color.black

    var body: some View {
        if let pen = prefs.pen(id) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(pen.name).font(.headline)
                    Spacer()
                    Button(role: .destructive) {
                        close()
                        prefs.pens.removeAll { $0.id == id }
                        if prefs.pens.isEmpty { prefs.pens = [Pen(type: "pen", color: "#111111")] }
                        model.refreshTools()
                    } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Remove this pen")
                }
                slider("Thickness", String(format: "%g", pen.size), Binding(get: { pen.size }, set: { v in change { $0.size = v } }), 1...12, 0.5)
                slider("Opacity", "\(Int(pen.opacity * 100))%", Binding(get: { pen.opacity * 100 }, set: { v in change { $0.opacity = v / 100 } }), 10...100, 5)
                Swatches(chosen: pen.color) { hex in change { $0.color = hex } }
            }
            .padding(18)
            .frame(width: 300)
        }
    }

    private func change(_ c: (inout Pen) -> Void) {
        prefs.update(id, c)
        model.refreshTools()
    }

    private func slider(_ name: String, _ value: String, _ b: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double) -> some View {
        VStack(spacing: 4) {
            HStack { Text(name).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
            Slider(value: b, in: range, step: step)
        }
    }
}

/// The colours: the nine of the web app, the ones lately picked, and the system's colour picker for any other.
struct Swatches: View {
    var chosen: String?
    let pick: (String) -> Void
    @ObservedObject private var prefs = Prefs.shared
    @State private var custom = Color.black

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 12), count: 5), spacing: 12) {
            ForEach(Prefs.colors + prefs.recent, id: \.self) { hex in
                Button { pick(hex) } label: {
                    Circle().fill(Color(uiColor: UIColor(hex: hex))).frame(width: 30, height: 30)
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                        .padding(4)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: chosen == hex ? 2.5 : 0))
                }
                .accessibilityLabel(hex)
            }
            ColorPicker("Another colour", selection: $custom, supportsOpacity: false).labelsHidden()
                .onChange(of: custom) { _, c in
                    let hex = UIColor(c).hex
                    prefs.remember(hex)
                    pick(hex)
                }
        }
    }
}

struct EraserPanel: View {
    @ObservedObject var model: EditorModel
    @AppStorage("eraserSize") private var size = 8.0
    @AppStorage("eraserPixels") private var pixels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Erases", selection: $pixels) {
                Text("Whole strokes").tag(false)
                Text("What it touches").tag(true)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 14) {
                Circle().fill(Color.primary.opacity(0.5)).frame(width: size + 4, height: size + 4).frame(width: 46, height: 46)
                Slider(value: $size, in: 4...40, step: 1).disabled(!pixels)
            }
        }
        .padding(18).frame(width: 320)
        .onChange(of: size) { _, _ in model.refreshTools() }
        .onChange(of: pixels) { _, _ in model.refreshTools() }
    }
}

struct TextPanel: View {
    @AppStorage("textSize") private var size = 28.0
    var body: some View {
        HStack(spacing: 14) {
            Text("Aa").font(.system(size: 10 + size / 3)).frame(width: 60, height: 46)
            Slider(value: $size, in: 16...96, step: 2)
        }
        .padding(18).frame(width: 320)
    }
}

struct SettingsPanel: View {
    @AppStorage("penShadow") private var shadow = true
    @AppStorage("pencilTap") private var tap = "eraser"
    @AppStorage("pencilSqueeze") private var squeeze = "undo"
    @AppStorage("followPen") private var follow = true
    @AppStorage("noteTabs") private var tabs = true
    @AppStorage("lecCam") private var lecCam = false
    @AppStorage("lecFull") private var lecFull = false
    @AppStorage("precheck") private var precheck = true

    var body: some View {
        Form {
            Section {
                Toggle("Pen shadow", isOn: $shadow)
                Picker("Pencil double-tap", selection: $tap) { ForEach(Prefs.pencilActions, id: \.0) { Text($0.1).tag($0.0) } }
                Picker("Pencil squeeze", selection: $squeeze) { ForEach(Prefs.pencilActions, id: \.0) { Text($0.1).tag($0.0) } }
                Toggle("Page follows pen", isOn: $follow)
                Toggle("Note tabs", isOn: $tabs)
            }
            Section("Lecture mode (16:9)") {
                Toggle("Camera bubble", isOn: $lecCam)
                Toggle("Full screen", isOn: $lecFull)
                Toggle("Check before recording", isOn: $precheck)
            }
            Section("The app") {
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            }
        }
        .frame(width: 400, height: 520)
    }
}

/// What can be done with what the lasso holds: a new colour, or the bin.
struct LassoBar: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Prefs.colors, id: \.self) { hex in
                Button { model.recolourSelection(hex) } label: {
                    Circle().fill(Color(uiColor: UIColor(hex: hex))).frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1)).frame(width: 34, height: 40)
                }
            }
            IconButton(symbol: "trash", label: "Delete the selected ink") { model.deleteSelection() }
        }
        .tint(.primary)
        .padding(.horizontal, 10).frame(height: 52)
        .glass()
    }
}

/// Zoom: out, the percentage (tap: 100%), in, fit width, light or dark.
struct ZoomStrip: View {
    @ObservedObject var model: EditorModel
    @AppStorage("theme") private var theme = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "minus", label: "Zoom out") { model.zoom(by: 1 / 1.25) }
            Button { model.view.scaleFactor = 1 } label: {
                Text(model.isFit ? "Fit" : "\(Int((model.view.scaleFactor * 100).rounded()))%").font(.callout.monospacedDigit()).frame(width: 52, height: 40)
            }
            .accessibilityLabel("Reset zoom to 100%")
            IconButton(symbol: "plus", label: "Zoom in") { model.zoom(by: 1.25) }
            IconButton(symbol: "arrow.left.and.right.square", label: "Fit width") { model.fitWidth() }
            IconButton(symbol: "circle.lefthalf.filled", label: "Light or dark") { theme = scheme == .dark ? "light" : "dark" }
        }
        .tint(.primary)
        .padding(.horizontal, 6).frame(height: 52)
        .glass()
    }
}
