import PDFKit
import SwiftUI

struct PDFEditor: UIViewRepresentable {
    let model: EditorModel

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.autoScales = true
        v.backgroundColor = .systemGray5
        v.pageOverlayViewProvider = model
        v.isInMarkupMode = true
        v.document = model.document
        model.pdfView = v
        return v
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// The notebook screen: the page with the system pen tray over it, and a bar of the things the tray lacks.
struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var showPages = false
    @State private var shareURL: URL?
    @State private var sharing = false

    init(info: NotebookInfo, store: Store) {
        _model = StateObject(wrappedValue: EditorModel(info: info, store: store))
    }

    var body: some View {
        NavigationStack {
            PDFEditor(model: model)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(model.info.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.saveNow()
                            dismiss()
                        } label: {
                            Label("Library", systemImage: "chevron.backward")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                            .keyboardShortcut("z", modifiers: .command)
                        Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                            .keyboardShortcut("z", modifiers: [.command, .shift])
                        Button { model.fingerDraws.toggle() } label: {
                            Image(systemName: model.fingerDraws ? "hand.draw.fill" : "hand.draw")
                        }
                        .accessibilityLabel("Draw with finger")
                        Button { showPages = true } label: { Image(systemName: "square.grid.2x2") }
                            .accessibilityLabel("Pages")
                        Button {
                            if let u = model.exportPDF() {
                                shareURL = u
                                sharing = true
                            }
                        } label: { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Export PDF")
                    }
                }
        }
        .sheet(isPresented: $showPages) { PagesSheet(model: model) }
        .sheet(isPresented: $sharing) { if let u = shareURL { ShareSheet(url: u) } }
        .onChange(of: phase) { _, p in if p != .active { model.saveNow() } }
        .onDisappear { model.saveNow() }
    }
}

/// Every page as a picture: tap to go there, and add or remove a page.
struct PagesSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    ForEach(0..<model.pageCount, id: \.self) { i in
                        Button {
                            model.go(to: i)
                            dismiss()
                        } label: {
                            VStack {
                                if let img = model.thumbnail(i, width: 300) {
                                    Image(uiImage: img).resizable().scaledToFit()
                                        .overlay(Rectangle().stroke(i == model.currentIndex ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: i == model.currentIndex ? 3 : 1))
                                }
                                Text("\(i + 1)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete page", systemImage: "trash") }
                        .disabled(model.pageCount < 2)
                    Button { model.addPage() } label: { Label("Add page", systemImage: "plus.square") }
                }
            }
            .confirmationDialog("Delete the page you were on?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete page", role: .destructive) { model.deleteCurrentPage() }
            }
        }
    }
}
