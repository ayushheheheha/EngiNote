import Foundation
import PDFKit

/// The library on disk: Documents/Notebooks/index.json, and one folder per notebook holding
/// pages.pdf (the paper or the imported PDF) and ink.plist (one PencilKit drawing per page).
@MainActor
final class Store: ObservableObject {
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var notebooks: [NotebookInfo] = []
    let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Notebooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: root.appendingPathComponent("index.json")) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let idx = try? dec.decode(LibraryIndex.self, from: data) {
                folders = idx.folders
                notebooks = idx.notebooks
            }
        }
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func pdfURL(_ id: String) -> URL { dir(id).appendingPathComponent("pages.pdf") }
    func inkURL(_ id: String) -> URL { dir(id).appendingPathComponent("ink.plist") }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(LibraryIndex(folders: folders, notebooks: notebooks)) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// A directory name made from an id that came from outside (a backup): letters, digits, - and _ only.
    private func safeID(_ wanted: String?) -> String {
        let clean = String((wanted ?? "").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(80))
        if clean.isEmpty || notebooks.contains(where: { $0.id == clean }) { return UUID().uuidString }
        return clean
    }

    // MARK: folders

    @discardableResult
    func addFolder(name: String, id: String = UUID().uuidString) -> Folder {
        let f = Folder(id: id, name: name, updatedAt: Date())
        folders.append(f)
        save()
        return f
    }

    func renameFolder(_ id: String, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        folders[i].updatedAt = Date()
        save()
    }

    /// The notebooks inside are kept, and go back to the main list.
    func deleteFolder(_ id: String) {
        for i in notebooks.indices where notebooks[i].folderID == id { notebooks[i].folderID = nil }
        folders.removeAll { $0.id == id }
        save()
    }

    // MARK: notebooks

    func create(name: String, paper: Paper, pages: Int, folder: String?) -> NotebookInfo? {
        let doc = PaperPDF.document(paper: paper, pages: max(1, pages))
        return add(id: nil, name: name, paper: paper, folderID: folder, updatedAt: Date(), document: doc, drawings: [])
    }

    @discardableResult
    func add(id: String?, name: String, paper: Paper, folderID: String?, updatedAt: Date, document: PDFDocument, drawings: [Data]) -> NotebookInfo? {
        let nid = safeID(id)
        try? FileManager.default.createDirectory(at: dir(nid), withIntermediateDirectories: true)
        guard document.write(to: pdfURL(nid)) else { return nil }
        if !drawings.isEmpty { writeDrawings(nid, drawings) }
        let info = NotebookInfo(id: nid, name: name, folderID: folderID, updatedAt: updatedAt, paper: paper)
        notebooks.append(info)
        save()
        return info
    }

    /// An imported PDF file becomes a notebook with that file as its pages.
    func importPDF(at url: URL, folder: String?) -> NotebookInfo? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard PDFDocument(url: url) != nil else { return nil }
        let nid = safeID(nil)
        try? FileManager.default.createDirectory(at: dir(nid), withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: url, to: pdfURL(nid)) } catch { return nil }
        var paper = Paper()
        paper.template = "plain"
        let info = NotebookInfo(id: nid, name: url.deletingPathExtension().lastPathComponent, folderID: folder, updatedAt: Date(), paper: paper)
        notebooks.append(info)
        save()
        return info
    }

    func rename(_ id: String, to name: String) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].name = name
        notebooks[i].updatedAt = Date()
        save()
    }

    func move(_ id: String, to folder: String?) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }), notebooks[i].folderID != folder else { return }
        notebooks[i].folderID = folder
        save()
    }

    func touch(_ id: String) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].updatedAt = Date()
        save()
    }

    func duplicate(_ id: String) {
        guard let src = notebooks.first(where: { $0.id == id }) else { return }
        let nid = safeID(nil)
        do { try FileManager.default.copyItem(at: dir(id), to: dir(nid)) } catch { return }
        var copy = src
        copy.id = nid
        copy.name = src.name + " copy"
        copy.updatedAt = Date()
        notebooks.append(copy)
        save()
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir(id))
        notebooks.removeAll { $0.id == id }
        save()
    }

    func hasNotebook(_ id: String) -> Bool { notebooks.contains { $0.id == id } }
    func hasFolder(_ id: String) -> Bool { folders.contains { $0.id == id } }

    // MARK: a notebook's files

    func readDrawings(_ id: String) -> [Data] {
        guard let d = try? Data(contentsOf: inkURL(id)) else { return [] }
        return (try? PropertyListDecoder().decode([Data].self, from: d)) ?? []
    }

    func writeDrawings(_ id: String, _ drawings: [Data]) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        if let d = try? enc.encode(drawings) { try? d.write(to: inkURL(id), options: .atomic) }
    }

    /// Written beside the old file and swapped in, because the open document may be reading the old one.
    func writePDF(_ doc: PDFDocument, id: String) {
        let tmp = dir(id).appendingPathComponent("pages.tmp.pdf")
        guard doc.write(to: tmp) else { return }
        _ = try? FileManager.default.replaceItemAt(pdfURL(id), withItemAt: tmp)
    }
}
