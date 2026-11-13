import AppKit
import BetterTeXCore

/// Typesets the math in agent replies with the local pdflatex, off the main thread, and keeps the
/// results for the session. Formulas come back as vector images tinted with the text colour.
final class MathRenderer {
    static let shared = MathRenderer()
    /// Set once the toolchain is detected; without pdflatex formulas stay as source.
    var tools: Toolchain?
    enum State { case ready(NSImage, descent: CGFloat), failed }
    /// TeX sets math at 10pt; chat text is 13pt.
    static let scale: CGFloat = 1.3
    private var cache: [String: State] = [:]
    /// Formula key → the requests still waiting on it.
    private var waiting: [String: [Int]] = [:]
    /// Request → its callback and how many of its formulas are still being typeset.
    private var pending: [Int: (left: Int, done: () -> Void)] = [:]
    private var nextRequest = 0
    private let queue = DispatchQueue(label: "dev.bettertex.math", qos: .userInitiated)

    private static func key(_ tex: String, _ display: Bool) -> String { (display ? "D:" : "I:") + tex }
    func state(_ tex: String, display: Bool) -> State? { cache[Self.key(tex, display)] }

    /// Typesets the formulas not seen yet and calls `done` on the main thread, once, when all of
    /// them are ready.
    func request(_ formulas: [(tex: String, display: Bool)], done: @escaping () -> Void) {
        guard let tools else { return }
        let id = nextRequest; nextRequest += 1
        var fresh: [(tex: String, display: Bool)] = [], keys = Set<String>()
        for formula in formulas {
            let key = Self.key(formula.tex, formula.display)
            guard cache[key] == nil, keys.insert(key).inserted else { continue }
            if waiting[key] == nil { fresh.append(formula) }
            waiting[key, default: []].append(id)
        }
        if !keys.isEmpty { pending[id] = (keys.count, done) }
        guard !fresh.isEmpty else { return }
        queue.async { [weak self] in
            let results = (try? MathTypesetter.render(fresh, tools: tools)) ?? fresh.map { _ in nil }
            let images = zip(fresh, results).map { formula, result -> State in
                guard let result, let image = Self.image(pdf: result.pdf, glyph: result.glyph) else { return .failed }
                return .ready(image, descent: CGFloat(result.glyph.depth + MathTypesetter.border) * Self.scale)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                var callbacks: [() -> Void] = []
                for (formula, state) in zip(fresh, images) {
                    let key = Self.key(formula.tex, formula.display)
                    self.cache[key] = state
                    for id in self.waiting.removeValue(forKey: key) ?? [] {
                        guard var entry = self.pending[id] else { continue }
                        entry.left -= 1
                        if entry.left > 0 { self.pending[id] = entry } else { self.pending[id] = nil; callbacks.append(entry.done) }
                    }
                }
                callbacks.forEach { $0() }
            }
        }
    }
    /// One page of the batch, drawn in the current text colour so it follows light and dark mode.
    private static func image(pdf: Data, glyph: MathTypesetter.Glyph) -> NSImage? {
        guard let rep = NSPDFImageRep(data: pdf), glyph.page < rep.pageCount else { return nil }
        rep.currentPage = glyph.page
        let size = NSSize(width: rep.bounds.width * scale, height: rep.bounds.height * scale)
        guard size.width > 0, size.height > 0 else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            rep.draw(in: rect)
            Theme.text.set(); rect.fill(using: .sourceAtop)
            return true
        }
    }
}
