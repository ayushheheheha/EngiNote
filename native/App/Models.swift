import Foundation

/// What a blank page looks like. Same fields as the web app's paper, so a backup maps straight over.
struct Paper: Codable, Equatable, Hashable {
    var size = "A4"            // A4, Letter, 16:9, 4:3
    var horizontal = false
    var template = "rule"      // plain, rule, grid, dot, cornell, planner
    var color = "#ffffff"
    var line = "#c8ccd6"
    var spacing = 3            // 1...8

    static let width: Double = 900   // a page is 900 points wide, like the web app's page px
    static let ratios: [String: Double] = ["A4": 297.0 / 210, "Letter": 11.0 / 8.5, "16:9": 16.0 / 9, "4:3": 4.0 / 3]
    static let sizes = ["A4", "Letter", "16:9", "4:3"]
    static let templates = ["plain", "rule", "grid", "dot", "cornell", "planner"]

    var pageHeight: Double {
        let r = Paper.ratios[size] ?? 297.0 / 210
        return (horizontal ? Paper.width / r : Paper.width * r).rounded()
    }
}

struct Folder: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var updatedAt: Date
}

struct NotebookInfo: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var folderID: String?
    var updatedAt: Date
    var paper: Paper
    var imported: Bool?   // made from a PDF or a web page, not a blank notebook
}

struct LibraryIndex: Codable {
    var folders: [Folder] = []
    var notebooks: [NotebookInfo] = []
}
