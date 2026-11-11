import PDFKit
import SwiftUI

/// The notes that are open, as tabs (up to five), and which is in front. Remembered between launches.
@MainActor
final class Workspace: ObservableObject {
    static let most = 5
    @Published var open: [EditorModel] = []
    @Published var frontID: String?
    @Published var showing = false
    var store: Store!

    var front: EditorModel? { open.first { $0.id == frontID } ?? open.last }

    func show(_ info: NotebookInfo) {
        if !open.contains(where: { $0.id == info.id }) {
            if open.count >= Workspace.most, let oldest = open.first(where: { $0.id != frontID }) {
                Notice.shared.say("Five notes are open: “\(oldest.info.name)” was closed.")
                close(oldest.id)
            }
            open.append(EditorModel(info: info, store: store))
        }
        frontID = info.id
        showing = true
        remember()
    }

    func bring(_ id: String) {
        front?.saveNow()
        frontID = id
        remember()
    }

    func close(_ id: String) {
        guard let i = open.firstIndex(where: { $0.id == id }) else { return }
        open[i].saveNow()
        open.remove(at: i)
        if frontID == id { frontID = open.last?.id }
        if open.isEmpty { showing = false }
        remember()
    }

    /// Back to the library; the tabs wait there.
    func toLibrary() {
        open.forEach { $0.saveNow() }
        showing = false
        remember()
    }

    func remember() {
        UserDefaults.standard.set(["ids": open.map(\.id), "front": frontID ?? "", "showing": showing], forKey: "session")
    }

    /// Opening the app goes back to where it was left: the open tabs, and the note in front if one was.
    func restore(_ store: Store) {
        guard self.store == nil else { return }
        self.store = store
        guard let s = UserDefaults.standard.dictionary(forKey: "session"), let ids = s["ids"] as? [String] else { return }
        open = ids.prefix(Workspace.most).compactMap { id in store.notebooks.first { $0.id == id }.map { EditorModel(info: $0, store: store) } }
        frontID = (s["front"] as? String).flatMap { f in open.contains { $0.id == f } ? f : nil } ?? open.last?.id
        showing = (s["showing"] as? Bool ?? false) && !open.isEmpty
    }
}

/// Holds an open note's own PDF view, which lives as long as its tab: the place, the zoom and undo stay with it.
struct PDFHost: UIViewRepresentable {
    let model: EditorModel

    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        let v = model.view
        v.removeFromSuperview()
        v.frame = box.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.addSubview(v)
        return box
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// The in-app browser over the note (the web-based app's BrowserPane). It is kept, so closing and opening finds the site where it was left.
struct BrowserHost: UIViewRepresentable {
    static let pane = BrowserPane(frame: .zero)
    let close: () -> Void

    final class Box: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            BrowserHost.pane.open(at: bounds, held: false)
        }
    }

    func makeUIView(context: Context) -> Box {
        let box = Box()
        let pane = BrowserHost.pane
        pane.removeFromSuperview()
        pane.onClose = close
        pane.presenter = UIApplication.top
        box.addSubview(pane)
        return box
    }

    func updateUIView(_ uiView: Box, context: Context) {}
    static func dismantleUIView(_ uiView: Box, coordinator: ()) { pane.close() }
}

/// The editor: the open note with the tray, the tabs, the panes that float over it, and the recording bar.
struct WorkspaceView: View {
    @ObservedObject var work: Workspace
    @StateObject private var chrome = Chrome()
    @ObservedObject private var rec = Recording.shared
    @ObservedObject private var notice = Notice.shared
    @AppStorage("noteTabs") private var tabsOn = true
    @AppStorage("recMin") private var recSmall = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        GeometryReader { geo in
            let band = max(0, (geo.size.height - geo.size.width * 9 / 16) / 2)   // the black band above and below the 16:9 window
            ZStack {
                (chrome.wide ? Color.black : Color(uiColor: .systemGray6)).ignoresSafeArea()
                if let model = work.front {
                    editor(model, top: chrome.wide ? 0 : geo.safeAreaInsets.top)
                        .frame(width: geo.size.width, height: chrome.wide ? min(geo.size.height, geo.size.width * 9 / 16) : geo.size.height)
                        .clipped()
                }
                VStack {
                    Spacer()
                    RecBar().padding(.bottom, chrome.wide ? max(6, (band - 52) / 2) : 14)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: recSmall ? .leading : .center)
                if rec.state == .counting {
                    Text("\(rec.count)").font(.system(size: 180, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 20).allowsHitTesting(false)
                }
                if rec.asking { Precheck() }
                if let text = notice.text {
                    VStack {
                        Spacer()
                        Text(text).font(.callout).multilineTextAlignment(.center)
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            .glass()
                            .padding(.bottom, 80).padding(.horizontal, 40)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: notice.text)
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: phase) { _, p in
            if p != .active { work.open.forEach { $0.saveNow() } }
            rec.away(p != .active)
        }
        .onChange(of: work.frontID, initial: true) { _, _ in rec.title = work.front?.info.name ?? "" }
        .onDisappear { if chrome.wide { chrome.setWide(false) } }
        .task { await SelfTest.run(work, chrome) }
    }

    private func editor(_ model: EditorModel, top: CGFloat) -> some View {
        VStack(spacing: 6) {
            if !chrome.full, !chrome.toolsOff {
                TopBar(model: model, chrome: chrome, back: work.toLibrary)
                    .padding(.horizontal, 10).padding(.top, top + 8)
            }
            if tabsOn, !chrome.wide, !chrome.toolsOff, !work.open.isEmpty {
                TabStrip(work: work).padding(.horizontal, 10).padding(.top, chrome.full ? top + 8 : 0)
            }
            ZStack {
                PDFHost(model: model).id(model.id)
                if chrome.browser { BrowserHost { chrome.browser = false } }
                if chrome.pages {
                    PagesPanel(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if chrome.full, !chrome.toolsOff {
                    Tray(model: model, chrome: chrome, vertical: true)
                        .frame(width: 56).glass(RoundedRectangle(cornerRadius: 28))
                        .padding(.vertical, 50).padding(.trailing, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
                if model.hasSelection {
                    LassoBar(model: model).padding(.bottom, 84).frame(maxHeight: .infinity, alignment: .bottom)
                }
                if chrome.calc { CalcPane(open: $chrome.calc) }
                // the small arrow that puts the tools away, and brings them back
                Button { withAnimation(.spring(duration: 0.3)) { chrome.toolsOff.toggle() } } label: {
                    Image(systemName: chrome.toolsOff ? "chevron.down" : "chevron.up").font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 22).glass()
                }
                .tint(.primary)
                .padding(.trailing, chrome.full && !chrome.toolsOff ? 80 : 12).padding(.top, chrome.toolsOff ? top + 6 : 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .accessibilityLabel(chrome.toolsOff ? "Show the tools" : "Put the tools away")
            }
        }
        .background(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1) : .systemGray5 }))
    }
}

/// Along the top: back and the note's name, zoom, and the tools in one line that slides sideways.
struct TopBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var chrome: Chrome
    let back: () -> Void
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                IconButton(symbol: "chevron.left", label: "Back to library", action: back)
                TextField("Name", text: $name)
                    .font(.callout.weight(.semibold)).frame(width: 190).submitLabel(.done)
                    .onSubmit { model.rename(name); name = model.info.name }
            }
            .tint(.primary)
            .padding(.leading, 6).padding(.trailing, 14).frame(height: 52)
            .glass()
            ZoomStrip(model: model)
            Tray(model: model, chrome: chrome, vertical: false)
                .frame(height: 52)
                .clipShape(Capsule())
                .glass()
        }
        .onAppear { name = model.info.name }
        .onChange(of: model.id) { _, _ in name = model.info.name }
    }
}

/// The open notes: a bar the tabs share between them, each with a round cross at its left and its name in the middle.
struct TabStrip: View {
    @ObservedObject var work: Workspace

    var body: some View {
        HStack(spacing: 6) {
            ForEach(work.open) { m in
                let front = m.id == work.front?.id
                HStack(spacing: 4) {
                    Button { work.close(m.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                            .background(Color.primary.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("Close \(m.info.name)")
                    Text(m.info.name).font(.callout.weight(front ? .semibold : .regular)).lineLimit(1).frame(maxWidth: .infinity)
                    if Recording.shared.state != .idle, front { Circle().fill(.red).frame(width: 8, height: 8) }
                }
                .padding(.horizontal, 8).frame(height: 34)
                .background(front ? Color.primary.opacity(0.14) : .clear, in: Capsule())
                .contentShape(Capsule())
                .onTapGesture { work.bring(m.id) }
                .contextMenu {
                    Button("Close the other tabs") { work.open.map(\.id).filter { $0 != m.id }.forEach(work.close) }
                }
            }
        }
        .tint(.primary)
        .padding(4)
        .glass()
    }
}

/// The pages as a column of small pictures: tap to jump, press and drag to reorder, and a menu on each
/// (add, duplicate, its own paper, delete).
struct PagesPanel: View {
    @ObservedObject var model: EditorModel
    private let colours = [("White", "#ffffff"), ("Cream", "#fbf2d8"), ("Black", "#111111")]

    var body: some View {
        List {
            ForEach(0..<model.pageCount, id: \.self) { i in
                VStack(spacing: 4) {
                    PageThumb(model: model, index: i)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(i == model.pageIndex ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: i == model.pageIndex ? 3 : 1))
                        .overlay(alignment: .topTrailing) { menu(i) }
                    Text("\(i + 1)").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.go(to: i) }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
            .onMove { from, to in
                guard let f = from.first else { return }
                model.movePage(from: f, to: to > f ? to - 1 : to)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(width: 170)
        .glass(RoundedRectangle(cornerRadius: 22))
        .padding(.leading, 10).padding(.vertical, 10)
    }

    private func menu(_ i: Int) -> some View {
        Menu {
            Button { model.addPage(after: i) } label: { Label("Add a page after", systemImage: "plus.rectangle.portrait") }
            Button { model.duplicatePage(i) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Menu("Template") {
                ForEach(Paper.templates, id: \.self) { t in Button(t.capitalized) { model.restyle(i, template: t) } }
            }
            Menu("Colour") {
                ForEach(colours, id: \.1) { c in Button(c.0) { model.restyle(i, color: c.1) } }
            }
            Button(role: .destructive) { model.deletePage(i) } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.pageCount < 2)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).frame(width: 26, height: 26)
                .background(.regularMaterial, in: Circle()).padding(4)
        }
        .tint(.primary)
    }
}

struct PageThumb: View {
    let model: EditorModel
    let index: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() } else { Color.white.aspectRatio(0.7, contentMode: .fit) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(index)-\(model.pageCount)-\(model.pageIndex == index)") { image = model.thumbnail(index, width: 280) }
    }
}
