import JavaScriptCore
import SwiftUI

/// The scientific calculator (Casio fx-991ES Plus style). The sums are worked out by the web app's own
/// calc.js, run here as a plain script (no web view), so the answers are exactly the same: exact
/// fractions, S⇔D, mixed numbers. This file only draws the keys and the display.
@MainActor
final class Calc: ObservableObject {
    struct Key: Decodable {
        let label: String
        let cls: String
        let alt: String?
    }
    struct Shown: Decodable {
        var sum = "", answer = "0", mini = "Calculator"
        var second = false, deg = true, bad = false
    }

    @Published var shown = Shown()
    private(set) var rows: [[Key]] = []
    private let js = JSContext()

    // The keys' state and what a press does: calc.js's own `press`, with the state held here instead of in a page.
    private static let shim = #"""
    let sum = '', cursor = 0, done = false, error = '', answer = frac(0n);
    let deg = true, second = false, asDecimal = false, asMixed = false;
    const typedNumber = () => /[\d.⁄⌟E]+$/.exec(sum.slice(0, cursor))?.[0] ?? '';
    const wholeAtEnd = () => { const m = /(.?)(\d+)$/.exec(sum.slice(0, cursor)); return !!m && !(m[1] && '.⌟⁄E'.includes(m[1])); };
    const stops = () => [0, ...[...sum.matchAll(/asin\(|acos\(|atan\(|sin\(|cos\(|tan\(|ln\(|log\(|√\(|∛\(|\^\(|Ans|[^]/gu)].map(m => m.index + m[0].length)];
    const insert = text => { if (sum.length < 160) { sum = sum.slice(0, cursor) + text + sum.slice(cursor); cursor += text.length; } };
    function calcKeys() { return JSON.stringify(ROWS.map(r => r.map(k => ({ label: k.label, cls: k.cls, alt: k.alt ? k.alt[0] : null })))); }
    function calcState() {
      const typing = !done && !error;
      const shown = done ? format(answer, { dec: asDecimal, mixed: asMixed }) : null;
      return JSON.stringify({ sum: sumHtml(sum, typing ? cursor : -1), answer: error || (shown ? shown.html : sum ? '' : '0'),
        mini: shown ? shown.text : 'Calculator', second, deg, bad: !!error });
    }
    function calcPress(r, c) {
      const k = ROWS[r][c], was2 = second;
      second = false;
      if (k.act === 'second') second = !was2;
      else if (k.act === 'deg') deg = !deg;
      else if (k.act === 'clear') { sum = ''; cursor = 0; done = false; error = ''; }
      else if (k.act === 'back') {
        if (done || error) { done = false; error = ''; cursor = sum.length; }
        const before = stops().filter(x => x < cursor).pop();
        if (before !== undefined) { sum = sum.slice(0, before) + sum.slice(cursor); cursor = before; }
      } else if (k.act === 'left') {
        if (done || error) { done = false; error = ''; cursor = sum.length; } else cursor = stops().filter(x => x < cursor).pop() ?? 0;
      } else if (k.act === 'right') {
        if (done || error) { done = false; error = ''; cursor = 0; } else cursor = stops().find(x => x > cursor) ?? sum.length;
      } else if (k.act === 'eval') {
        if (!sum) return calcState();
        try {
          const v = evaluate(sum, { ans: answer, deg });
          answer = v; done = true; asDecimal = false; asMixed = false;
        } catch (e) { error = /ERROR$/.test(e.message) ? e.message : SYNTAX; }
      } else if (k.act === 'toggle') {
        if (done && isFraction(answer) && answer.d !== 1n) asDecimal = !asDecimal;
      } else if (k.act === 'mixed') {
        if (done) { if (isFraction(answer) && answer.d !== 1n) { asMixed = !asMixed; asDecimal = false; } } else if (wholeAtEnd()) insert('⌟');
      } else if (k.act === 'frac') {
        const n = typedNumber();
        if (!done && /\d$/.test(n) && !n.includes('⁄') && !n.includes('E')) insert('⁄');
      } else {
        if (error) { sum = ''; cursor = 0; error = ''; done = false; }
        if (done) { sum = k.post ? 'Ans' : ''; cursor = sum.length; done = false; }
        insert(was2 && k.alt ? k.alt[1] : k.insert);
      }
      return calcState();
    }
    """#

    init() {
        if let url = Bundle.main.url(forResource: "calc", withExtension: "js"), let src = try? String(contentsOf: url, encoding: .utf8) {
            js?.evaluateScript(EditorModel.plainScript(src))
            js?.evaluateScript(Calc.shim)
        }
        let keys = js?.evaluateScript("calcKeys()")?.toString().flatMap { $0.data(using: .utf8) }
        rows = keys.flatMap { try? JSONDecoder().decode([[Key]].self, from: $0) } ?? []
        take(js?.evaluateScript("calcState()"))
        if SelfTest.has("-demo-panes") { for (r, c) in [(3, 3), (0, 6), (3, 5), (4, 6)] { press(r, c) } }   // 1 ÷ 3 =
    }

    func press(_ r: Int, _ c: Int) { take(js?.evaluateScript("calcPress(\(r), \(c))")) }

    private func take(_ v: JSValue?) {
        if let d = v?.toString().data(using: .utf8), let s = try? JSONDecoder().decode(Shown.self, from: d) { shown = s }
    }
}

/// The little HTML calc.js writes its display and key labels in: text, <sup>, a stacked fraction, an empty box, the cursor.
indirect enum Markup {
    case text(String), sup([Markup]), frac([Markup], [Markup]), box, caret, icon(String)

    static func parse(_ html: String) -> [Markup] {
        var rest = Substring(html)
        return nodes(&rest, until: nil)
    }

    private static func nodes(_ s: inout Substring, until close: String?) -> [Markup] {
        var out: [Markup] = [], text = ""
        func flush() { if !text.isEmpty { out.append(.text(text)); text = "" } }
        func eat(_ p: String) -> Bool { if s.hasPrefix(p) { s.removeFirst(p.count); return true }; return false }
        while !s.isEmpty {
            if let close, eat(close) { break }
            if eat("<sup>") { flush(); out.append(.sup(nodes(&s, until: "</sup>"))) }
            else if eat("<span class=\"frac\">") {
                flush()
                var top: [Markup] = [], bottom: [Markup] = []
                if eat("<span>") { top = nodes(&s, until: "</span>") }
                if eat("<span>") { bottom = nodes(&s, until: "</span>") }
                _ = eat("</span>")
                out.append(.frac(top, bottom))
            }
            else if eat("<i class=\"box\"></i>") { flush(); out.append(.box) }
            else if eat("<i class=\"caret\"></i>") { flush(); out.append(.caret) }
            else if s.hasPrefix("<svg") {
                flush()
                let end = s.range(of: "</svg>")
                out.append(.icon(s[..<(end?.lowerBound ?? s.endIndex)].contains("M15 5") ? "chevron.left" : "chevron.right"))
                s = end.map { s[$0.upperBound...] } ?? ""
            }
            else if eat("&amp;") { text += "&" }
            else if eat("&lt;") { text += "<" }
            else { text.append(s.removeFirst()) }
        }
        flush()
        return out
    }
}

struct MarkupView: View {
    let nodes: [Markup]
    var size: CGFloat = 17

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, n in piece(n) }
        }
    }

    @ViewBuilder private func piece(_ n: Markup) -> some View {
        switch n {
        case .text(let t): Text(t).font(.system(size: size, design: .rounded))
        case .sup(let inner): MarkupView(nodes: inner, size: size * 0.65).offset(y: -size * 0.35)
        case .frac(let top, let bottom):
            VStack(spacing: 1) {
                MarkupView(nodes: top, size: size * 0.8)
                Rectangle().frame(height: 1.2)
                MarkupView(nodes: bottom, size: size * 0.8)
            }
            .fixedSize()
            .padding(.horizontal, 2)
        case .box: RoundedRectangle(cornerRadius: 2).stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: size * 0.5, height: size * 0.7).padding(1)
        case .caret: Rectangle().fill(Color.accentColor).frame(width: 2, height: size * 1.1)
        case .icon(let name): Image(systemName: name).font(.system(size: size * 0.9, weight: .semibold))
        }
    }
}

/// The pane: floats over the note, dragged by its handle, shrunk to a chip with the dash, closed with the cross.
struct CalcPane: View {
    @Binding var open: Bool
    @StateObject private var calc = Calc()
    @AppStorage("calcX") private var x = 0.0
    @AppStorage("calcY") private var y = 0.0
    @AppStorage("calcMin") private var small = false
    @GestureState private var pull = CGSize.zero

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { withAnimation(.spring(duration: 0.3)) { small.toggle() } } label: { Image(systemName: small ? "plus" : "minus").frame(width: 30, height: 30) }
                VStack(spacing: 3) {
                    Capsule().fill(.secondary).frame(width: 36, height: 4)
                    if small { Text(calc.shown.mini).font(.callout.monospacedDigit()).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .global).updating($pull) { v, s, _ in s = v.translation }
                    .onEnded { v in x += v.translation.width; y += v.translation.height })
                Button { open = false } label: { Image(systemName: "xmark").frame(width: 30, height: 30) }
            }
            if !small {
                VStack(alignment: .trailing, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) { MarkupView(nodes: Markup.parse(calc.shown.sum), size: 20) }
                        .frame(height: 44).defaultScrollAnchor(.trailing)
                    MarkupView(nodes: Markup.parse(calc.shown.answer), size: 28)
                        .foregroundStyle(calc.shown.bad ? Color.red : .primary)
                        .frame(height: 50)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                ForEach(Array(calc.rows.enumerated()), id: \.offset) { r, row in
                    HStack(spacing: 6) {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, k in key(k, r, c) }
                    }
                }
            }
        }
        .tint(.primary)
        .padding(12)
        .frame(width: small ? 220 : 372)
        .glass(RoundedRectangle(cornerRadius: 24))
        .offset(x: x + pull.width, y: y + pull.height)
    }

    private func key(_ k: Calc.Key, _ r: Int, _ c: Int) -> some View {
        let wide = k.cls.contains("span3")
        let label: String = k.cls.contains("tog") && c == 1 ? (calc.shown.deg ? "DEG" : "RAD") : (calc.shown.second ? k.alt ?? k.label : k.label)
        let fill: Color = k.cls.contains("eq") ? .accentColor : k.cls.contains("op") ? .orange.opacity(0.85)
            : k.cls.contains("clr") ? .red.opacity(0.7) : k.cls.contains("fn") ? Color.primary.opacity(0.1) : Color.primary.opacity(0.2)
        return Button { calc.press(r, c) } label: {
            MarkupView(nodes: Markup.parse(label), size: k.cls.contains("fn") ? 14 : 18)
                .frame(width: wide ? 44 * 3 + 12 : 44, height: 40)
                .background(c == 0 && r == 0 && calc.shown.second ? Color.accentColor.opacity(0.5) : fill, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
