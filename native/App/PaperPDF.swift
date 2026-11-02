import PDFKit
import UIKit

extension UIColor {
    /// "#rrggbb" (anything else is black).
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        if s.count == 6, Scanner(string: s).scanHexInt64(&v) {
            self.init(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        } else {
            self.init(white: 0, alpha: 1)
        }
    }
}

/// Paper as PDF pages: every notebook is a PDF underneath, so PDFKit gives scrolling, zoom and thumbnails.
enum PaperPDF {
    static func document(paper: Paper, pages: Int) -> PDFDocument {
        let size = CGSize(width: Paper.width, height: paper.pageHeight)
        let rect = CGRect(origin: .zero, size: size)
        let data = UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            for _ in 0..<pages {
                ctx.beginPage()
                draw(paper, template: paper.template, color: paper.color, in: rect, ctx.cgContext)
            }
        }
        return PDFDocument(data: data) ?? PDFDocument()
    }

    /// One new page of this paper, in the size given.
    static func blankPage(paper: Paper, size: CGSize, template: String? = nil, color: String? = nil) -> PDFPage {
        let rect = CGRect(origin: .zero, size: size)
        let data = UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            ctx.beginPage()
            draw(paper, template: template ?? paper.template, color: color ?? paper.color, in: rect, ctx.cgContext)
        }
        let page = PDFDocument(data: data)?.page(at: 0)
        return (page?.copy() as? PDFPage) ?? PDFPage()
    }

    static func draw(_ p: Paper, template: String, color: String, in rect: CGRect, _ c: CGContext) {
        UIColor(hex: color).setFill()
        c.fill(rect)
        let w = rect.width, h = rect.height
        let k = w / CGFloat(Paper.width)
        let s = CGFloat(8 * (p.spacing + 1)) * k
        let line = UIColor(hex: p.line).cgColor
        c.setStrokeColor(line)
        c.setFillColor(line)
        c.setLineWidth(max(0.5, k))
        func hline(_ y: CGFloat) { c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: w, y: y)); c.strokePath() }
        func vline(_ x: CGFloat) { c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: h)); c.strokePath() }
        func rules() { var y = s; while y < h { hline(y); y += s } }
        switch template {
        case "rule":
            rules()
        case "grid":
            rules()
            var i: CGFloat = 0
            while w / 2 + i * s < w {
                vline(w / 2 + i * s)
                if i > 0 { vline(w / 2 - i * s) }
                i += 1
            }
        case "dot":
            var y = s / 2
            while y < h {
                var i: CGFloat = 0
                while w / 2 + i * s < w {
                    let xs: [CGFloat] = i == 0 ? [w / 2] : [w / 2 + i * s, w / 2 - i * s]
                    for x in xs {
                        c.fillEllipse(in: CGRect(x: x - 1.5 * k, y: y - 1.5 * k, width: 3 * k, height: 3 * k))
                    }
                    i += 1
                }
                y += s
            }
        case "cornell":
            rules()
            vline(w * 0.28)
            hline(h * 0.86)
        case "planner":
            for q in 1..<4 { hline(h * CGFloat(q) / 4) }
            vline(w / 2)
        default:
            break
        }
    }
}
