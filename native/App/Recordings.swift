import AVKit
import SwiftUI

/// A recording on disk: a .mov in Documents, or one waiting in "Recently Deleted".
struct Take: Identifiable, Hashable {
    let url: URL
    let size: Int
    let modified: Date
    var deleted: Date?
    var wrapped = false
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// The recordings and their bin (30 days, then gone): the same folders and the same hidden log the web-based app uses.
@MainActor
final class Clips: ObservableObject {
    static let keepDays = 30.0
    @Published var files: [Take] = []
    @Published var bin: [Take] = []

    private var root: URL? { try? Recorder.folder() }
    private var binFolder: URL? {
        guard let f = root?.appendingPathComponent("Recently Deleted", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }
    private var logURL: URL? { binFolder?.appendingPathComponent(".deleted.json") }
    private var log: [String: Double] {
        get { logURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:] }
        set { if let u = logURL, let d = try? JSONEncoder().encode(newValue) { try? d.write(to: u, options: .atomic) } }
    }

    private func movies(in folder: URL?) -> [Take] {
        guard let folder else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return found.filter { $0.pathExtension.lowercased() == "mov" }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Take(url: u, size: v?.fileSize ?? 0, modified: v?.contentModificationDate ?? .distantPast)
        }
    }

    func reload() {
        let active = Recording.shared.recorder.activeFile?.lastPathComponent
        files = movies(in: root).filter { $0.url.lastPathComponent != active }.map { c in
            var c = c
            c.wrapped = StudioWrap.marks(for: c.url) != nil
            return c
        }.sorted { $0.modified > $1.modified }
        var marks = log, now = Date().timeIntervalSince1970 * 1000
        var kept: [Take] = []
        for var c in movies(in: binFolder) {
            let name = c.url.lastPathComponent
            let at = marks[name] ?? now
            marks[name] = at
            if now - at > Clips.keepDays * 86_400_000 {   // it has waited its time
                erase(c.url)
                marks[name] = nil
                continue
            }
            c.deleted = Date(timeIntervalSince1970: at / 1000)
            kept.append(c)
        }
        if marks != log { log = marks }
        bin = kept.sorted { ($0.deleted ?? .distantPast) > ($1.deleted ?? .distantPast) }
    }

    /// Into the bin. Its Studio notes stay where they are, under its name, so that a restore finds them.
    func delete(_ clips: [Take]) {
        guard let folder = binFolder else { return }
        var marks = log
        for c in clips {
            var target = folder.appendingPathComponent(c.url.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) { target = folder.appendingPathComponent(String(UUID().uuidString.prefix(6)) + " " + c.url.lastPathComponent) }
            if (try? FileManager.default.moveItem(at: c.url, to: target)) != nil { marks[target.lastPathComponent] = Date().timeIntervalSince1970 * 1000 }
        }
        log = marks
        reload()
        Notice.shared.say("\(clips.count == 1 ? "1 recording" : "\(clips.count) recordings") moved to Recently Deleted, kept there for \(Int(Clips.keepDays)) days.")
    }

    func restore(_ clips: [Take]) {
        guard let root else { return }
        var marks = log
        for c in clips {
            var target = root.appendingPathComponent(c.url.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) { target = root.appendingPathComponent(c.name + " (restored).mov") }
            if (try? FileManager.default.moveItem(at: c.url, to: target)) != nil { marks[c.url.lastPathComponent] = nil }
        }
        log = marks
        reload()
    }

    func purge(_ clips: [Take]) {
        var marks = log
        for c in clips {
            erase(c.url)
            marks[c.url.lastPathComponent] = nil
        }
        log = marks
        reload()
    }

    /// Gone for good: the movie, and everything kept about it.
    private func erase(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        StudioWrap.forget(file)
        if let notes = Sidecar.url(for: file) { try? FileManager.default.removeItem(at: notes) }
        ClipPicture.cache.removeObject(forKey: file.path as NSString)
    }
}

enum ClipPicture {
    static let cache = NSCache<NSString, UIImage>()

    /// A frame a second in (past the intro, if it has one).
    static func make(_ movie: URL) async -> UIImage? {
        if let hit = cache.object(forKey: movie.path as NSString) { return hit }
        let img = await Task.detached(priority: .utility) { () -> UIImage? in
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 480, height: 270)
            let lead = StudioWrap.marks(for: movie)?.lead ?? 0
            let frame = (try? g.copyCGImage(at: CMTime(seconds: lead + 1, preferredTimescale: 600), actualTime: nil)) ?? (try? g.copyCGImage(at: .zero, actualTime: nil))
            return frame.map { UIImage(cgImage: $0) }
        }.value
        if let img { cache.setObject(img, forKey: movie.path as NSString) }
        return img
    }
}

/// The Recordings folder of the library: play, edit, Studio, intro and outro, share, delete; the bin; choosing several.
struct RecordingsView: View {
    @StateObject private var clips = Clips()
    @State private var inBin = false
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var confirmPurge: [Take]?

    private var shown: [Take] { inBin ? clips.bin : clips.files }
    private var chosen: [Take] { shown.filter { picked.contains($0.id) } }

    var body: some View {
        Group {
            if shown.isEmpty {
                ContentUnavailableView(inBin ? "Nothing deleted" : "No recordings yet", systemImage: inBin ? "trash" : "video",
                                       description: Text(inBin ? "Deleted recordings wait here for \(Int(Clips.keepDays)) days." : "Open a note and tap Record in the bar at the foot of the screen."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 24, alignment: .top)], spacing: 28) {
                        ForEach(shown) { c in card(c) }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle(inBin ? "Recently deleted" : "Recordings")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if inBin, !clips.bin.isEmpty { Button("Empty", role: .destructive) { confirmPurge = clips.bin } }
                Button(selecting ? "Done" : "Select") { selecting.toggle(); picked = [] }.disabled(shown.isEmpty)
                Button { inBin.toggle(); selecting = false; picked = [] } label: {
                    Label(inBin ? "Recordings" : "Recently deleted (\(clips.bin.count))", systemImage: inBin ? "video" : "trash")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack(spacing: 14) {
                    Text("\(picked.count) chosen").foregroundStyle(.secondary)
                    Button("Select all") { picked = Set(shown.map(\.id)) }
                    if inBin {
                        Button("Restore") { clips.restore(chosen); picked = [] }
                        Button("Delete", role: .destructive) { confirmPurge = chosen }
                    } else {
                        Button("Share") { UIApplication.share(chosen.map(\.url)) }
                        Button("Delete", role: .destructive) { clips.delete(chosen); picked = [] }
                    }
                }
                .padding(.horizontal, 18).frame(height: 52)
                .glass()
                .padding(.bottom, 10)
            }
        }
        .confirmationDialog("Delete for good?", isPresented: Binding(get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } }), titleVisibility: .visible) {
            Button("Delete \(confirmPurge?.count ?? 0) for good", role: .destructive) {
                clips.purge(confirmPurge ?? [])
                picked = []
            }
        } message: { Text("This cannot be undone.") }
        .onAppear { clips.reload() }
    }

    private func card(_ c: Take) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ClipThumb(url: c.url)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if selecting {
                        Image(systemName: picked.contains(c.id) ? "checkmark.circle.fill" : "circle").font(.title2)
                            .foregroundStyle(.white, Color.accentColor).padding(8)
                    }
                }
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            Text(c.name).font(.headline).lineLimit(1)
            Text("\(c.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(c.size), countStyle: .file))\(c.wrapped ? " · intro + outro" : "")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) } } else if !inBin { play(c) }
        }
        .contextMenu {
            if inBin {
                Button { clips.restore([c]) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                Button(role: .destructive) { confirmPurge = [c] } label: { Label("Delete for good", systemImage: "trash") }
            } else {
                Button { play(c) } label: { Label("Play", systemImage: "play") }
                Button { edit(c) } label: { Label("Trim and cut", systemImage: "scissors") }
                Button { studio(c) } label: { Label("Studio", systemImage: "wand.and.stars") }
                Button {
                    Task {
                        Notice.shared.say(await Recording.wrap(c.url, add: !c.wrapped))
                        clips.reload()
                    }
                } label: { Label(c.wrapped ? "Remove the intro and outro" : "Add the intro and outro", systemImage: "film") }
                Button { UIApplication.share([c.url]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { clips.delete([c]) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func play(_ c: Take) {
        let player = AVPlayerViewController()
        player.player = AVPlayer(url: c.url)
        UIApplication.top?.present(player, animated: true) { player.player?.play() }
    }

    private func edit(_ c: Take) {
        let editor = VideoEditor(file: c.url, busy: Recording.shared.recorder.activeFile?.lastPathComponent)
        editor.onSaved = { Task { @MainActor in clips.reload() } }
        UIApplication.top?.present(editor, animated: true)
    }

    private func studio(_ c: Take) {
        let studio = StudioViewController(movie: c.url)
        studio.onSaved = { Task { @MainActor in clips.reload() } }
        UIApplication.top?.present(studio, animated: true)
    }
}

struct ClipThumb: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color.black
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "video").foregroundStyle(.gray) }
        }
        .task(id: url) { image = await ClipPicture.make(url) }
    }
}
