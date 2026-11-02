import PDFKit
import PencilKit
import SwiftUI

/// A notebook's first page with its ink, drawn off the main thread and remembered until the note changes.
enum ThumbRender {
    static let cache = NSCache<NSString, UIImage>()

    @MainActor
    static func make(_ info: NotebookInfo, store: Store) async -> UIImage? {
        let key = "\(info.id)-\(info.updatedAt.timeIntervalSince1970)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let pdf = store.pdfURL(info.id), ink = store.inkURL(info.id)
        let img = await Task.detached(priority: .utility) { render(pdf, ink) }.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    static func render(_ pdfURL: URL, _ inkURL: URL) -> UIImage? {
        guard let doc = PDFDocument(url: pdfURL), let page = doc.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0 else { return nil }
        let size = CGSize(width: 360, height: 360 * box.height / box.width)
        let base = page.thumbnail(of: size, for: .mediaBox)
        var ink: UIImage?
        if let d = try? Data(contentsOf: inkURL),
           let all = try? PropertyListDecoder().decode([Data].self, from: d),
           let first = all.first, !first.isEmpty,
           let drawing = try? PKDrawing(data: first) {
            ink = drawing.image(from: CGRect(origin: .zero, size: box.size), scale: size.width / box.width)
        }
        return UIGraphicsImageRenderer(size: size).image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))
            ink?.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

struct Thumb: View {
    let info: NotebookInfo
    @EnvironmentObject private var store: Store
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.systemGray6)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: info.updatedAt) { image = await ThumbRender.make(info, store: store) }
    }
}
