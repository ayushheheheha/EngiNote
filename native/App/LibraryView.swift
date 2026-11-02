import SwiftUI
import UniformTypeIdentifiers

/// Folders down the side, notebooks as cards: the standard iPad split view.
struct LibraryView: View {
    @EnvironmentObject private var store: Store
    @State private var selection: String? = "all"          // "all", or a folder's id
    @State private var query = ""
    @State private var opened: NotebookInfo?
    @State private var showNew = false
    @State private var importing = false
    @State private var busy: String?
    @State private var message: String?

    // rename / delete
    @State private var renameTarget: Rename?
    @State private var renameText = ""
    @State private var deleteNotebook: NotebookInfo?
    @State private var deleteFolder: Folder?
    @State private var newFolderAsk = false
    @State private var newFolderName = ""

    struct Rename: Identifiable {
        let id: String
        let isFolder: Bool
    }

    private var currentFolder: String? { selection == "all" ? nil : selection }

    private var shown: [NotebookInfo] {
        store.notebooks
            .filter { selection == "all" || selection == nil || $0.folderID == selection }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .fullScreenCover(item: $opened) { info in
            EditorView(info: info, store: store)
        }
        .sheet(isPresented: $showNew) {
            NewNotebookSheet { name, paper, pages in
                if let info = store.create(name: name, paper: paper, pages: pages, folder: currentFolder) { opened = info }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .json], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { for u in urls { await handle(u) } } }
        }
        .onOpenURL { url in Task { await handle(url) } }
        .task {
            // the simulator check starts the app with -selftest: open a fresh notebook, to prove the editor stands up
            if CommandLine.arguments.contains("-selftest"), store.notebooks.isEmpty {
                opened = store.create(name: "Self test", paper: Paper(), pages: 2, folder: nil)
            }
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if let t = renameTarget, !name.isEmpty {
                    if t.isFolder { store.renameFolder(t.id, to: name) } else { store.rename(t.id, to: name) }
                }
            }
        }
        .alert("New folder", isPresented: $newFolderAsk) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { selection = store.addFolder(name: name).id }
            }
        }
        .confirmationDialog("Delete this notebook?", isPresented: Binding(get: { deleteNotebook != nil }, set: { if !$0 { deleteNotebook = nil } }), titleVisibility: .visible) {
            Button("Delete \(deleteNotebook?.name ?? "")", role: .destructive) { if let n = deleteNotebook { store.delete(n.id) } }
        } message: { Text("This cannot be undone.") }
        .confirmationDialog("Delete this folder?", isPresented: Binding(get: { deleteFolder != nil }, set: { if !$0 { deleteFolder = nil } }), titleVisibility: .visible) {
            Button("Delete \(deleteFolder?.name ?? "")", role: .destructive) {
                if let f = deleteFolder {
                    if selection == f.id { selection = "all" }
                    store.deleteFolder(f.id)
                }
            }
        } message: { Text("The notebooks inside are kept.") }
        .alert("EngiNote", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
        .overlay {
            if let busy {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(busy).font(.callout).multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label("All notebooks", systemImage: "books.vertical").tag("all" as String?)
            Section("Folders") {
                ForEach(store.folders) { f in
                    Label(f.name, systemImage: "folder")
                        .tag(f.id as String?)
                        .contextMenu {
                            Button { renameText = f.name; renameTarget = Rename(id: f.id, isFolder: true) } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { deleteFolder = f } label: { Label("Delete", systemImage: "trash") }
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            for id in ids { store.move(id, to: f.id) }
                            return true
                        }
                }
            }
        }
        .navigationTitle("EngiNote")
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button { newFolderName = ""; newFolderAsk = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
            }
        }
    }

    // MARK: notebooks

    private var detail: some View {
        let title = selection == "all" || selection == nil ? "All notebooks" : (store.folders.first { $0.id == selection }?.name ?? "Folder")
        return Group {
            if shown.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No notebooks yet" : "No matches", systemImage: "square.and.pencil",
                                       description: Text(query.isEmpty ? "Tap + to make one, or import a PDF or an EngiNote backup." : "Try another name."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 28, alignment: .top)], spacing: 32) {
                        ForEach(shown) { info in card(info) }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showNew = true } label: { Label("New notebook", systemImage: "square.and.pencil") }
                    Button { importing = true } label: { Label("Import PDF or backup", systemImage: "square.and.arrow.down") }
                } label: { Image(systemName: "plus") }
            }
        }
    }

    private func card(_ info: NotebookInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumb(info: info)
                .frame(height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            Text(info.name).font(.headline).lineLimit(1)
            Text(info.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 10))
        .onTapGesture { opened = info }
        .accessibilityAddTraits(.isButton)
        .draggable(info.id)
        .contextMenu {
            Button { opened = info } label: { Label("Open", systemImage: "book") }
            Button { renameText = info.name; renameTarget = Rename(id: info.id, isFolder: false) } label: { Label("Rename", systemImage: "pencil") }
            Button { store.duplicate(info.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Menu {
                Button("No folder") { store.move(info.id, to: nil) }
                ForEach(store.folders) { f in Button(f.name) { store.move(info.id, to: f.id) } }
            } label: { Label("Move to", systemImage: "folder") }
            Button(role: .destructive) { deleteNotebook = info } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: importing

    private func handle(_ url: URL) async {
        if url.pathExtension.lowercased() == "pdf" {
            if let info = store.importPDF(at: url, folder: currentFolder) { opened = info } else { message = "That PDF could not be opened." }
            return
        }
        busy = "Reading the backup…"
        defer { busy = nil }
        do {
            message = try await BackupImport.run(url: url, store: store) { busy = $0 }
        } catch {
            message = "That file could not be read: \(error.localizedDescription)"
        }
    }
}

/// Paper choices for a new notebook.
struct NewNotebookSheet: View {
    let onCreate: (String, Paper, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Untitled"
    @State private var paper = Paper()
    @State private var pages = 1

    private let colours: [(String, String, String)] = [
        ("White", "#ffffff", "#c8ccd6"),
        ("Cream", "#fdf6e3", "#d9cfa8"),
        ("Dark", "#1e1e22", "#44444c"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name) }
                Section("Paper") {
                    Picker("Size", selection: $paper.size) {
                        ForEach(Paper.sizes, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Direction", selection: $paper.horizontal) {
                        Text("Portrait").tag(false)
                        Text("Landscape").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Picker("Template", selection: $paper.template) {
                        ForEach(Paper.templates, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    Picker("Colour", selection: Binding(get: { paper.color }, set: { c in
                        paper.color = c
                        paper.line = colours.first { $0.1 == c }?.2 ?? paper.line
                    })) {
                        ForEach(colours, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    Stepper("Line spacing: \(paper.spacing)", value: $paper.spacing, in: 1...8)
                    Stepper("Pages: \(pages)", value: $pages, in: 1...100)
                }
                Section {
                    Image(uiImage: preview)
                        .resizable().scaledToFit().frame(maxHeight: 220)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("New notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        onCreate(n.isEmpty ? "Untitled" : n, paper, pages)
                        dismiss()
                    }
                }
            }
        }
    }

    private var preview: UIImage {
        let size = CGSize(width: 300, height: 300 * paper.pageHeight / Paper.width)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            // drawn at the real width and shrunk, so the line spacing looks as it will on the page
            ctx.cgContext.scaleBy(x: size.width / Paper.width, y: size.width / Paper.width)
            PaperPDF.draw(paper, template: paper.template, color: paper.color,
                          in: CGRect(x: 0, y: 0, width: Paper.width, height: paper.pageHeight), ctx.cgContext)
        }
    }
}
