import AppKit
import BetterTeXCore

final class EditorBuffer {
    let url: URL
    var text: String
    var snapshot: DiskSnapshot
    var dirty = false
    var selection = NSRange(location: 0, length: 0)
    init(url: URL) throws {
        self.url = url; snapshot = try DiskSnapshot(url: url)
        guard snapshot.data.count < 12_000_000, let contents = String(data: snapshot.data, encoding: .utf8) else { throw BetterTeXError.message("仅支持小于 12 MB 的 UTF-8 文本文件。") }
        text = contents
    }
    func save(overwrite: Bool = false) throws {
        guard dirty else { return }
        if !overwrite && !snapshot.isCurrent(at: url) { throw BetterTeXError.message("\(url.lastPathComponent) 已被外部程序修改。请先处理文件冲突。") }
        try text.write(to: url, atomically: true, encoding: .utf8)
        snapshot = try DiskSnapshot(url: url); dirty = false
    }
    func reload() throws {
        let fresh = try DiskSnapshot(url: url)
        guard let contents = String(data: fresh.data, encoding: .utf8) else { throw BetterTeXError.message("文件不是 UTF-8 文本。") }
        snapshot = fresh; text = contents; dirty = false
    }
}

/// The quick-insert commands offered above the editor and in the 插入 menu.
enum Snippet: Int, CaseIterable {
    case image, itemize, enumerate, equation, table, section, bold, italic, cite, ref
    var title: String { ["图片", "列表", "编号", "公式", "表格", "章节", "粗体", "斜体", "引用", "交叉引用"][rawValue] }
    var symbol: String { ["photo", "list.bullet", "list.number", "function", "tablecells", "number", "bold", "italic", "quote.opening", "link"][rawValue] }
    var help: String { ["插入图片（也可拖入或粘贴图片）", "无序列表 itemize", "有序列表 enumerate", "编号公式 equation", "三线表 table", "新章节 \\section", "粗体 \\textbf", "斜体 \\textit", "文献引用 \\cite", "交叉引用 \\ref"][rawValue] }
    /// Text placed before and after the selection, the placeholder used when nothing is selected,
    /// and whether the snippet must start on its own line.
    var template: (before: String, after: String, placeholder: String, block: Bool) {
        switch self {
        case .image: return ("", "", "", false)
        case .itemize: return ("\\begin{itemize}\n  \\item ", "\n\\end{itemize}\n", "条目", true)
        case .enumerate: return ("\\begin{enumerate}\n  \\item ", "\n\\end{enumerate}\n", "条目", true)
        case .equation: return ("\\begin{equation}\n  ", "\n\\end{equation}\n", "E = mc^2", true)
        case .table: return ("\\begin{table}[htbp]\n  \\centering\n  \\caption{", "}\n  \\begin{tabular}{lcc}\n    \\hline\n    项目 & A & B \\\\\n    \\hline\n    示例 & 1 & 2 \\\\\n    \\hline\n  \\end{tabular}\n\\end{table}\n", "表题", true)
        case .section: return ("\\section{", "}\n", "标题", true)
        case .bold: return ("\\textbf{", "}", "文本", false)
        case .italic: return ("\\textit{", "}", "文本", false)
        case .cite: return ("\\cite{", "}", "key", false)
        case .ref: return ("\\ref{", "}", "label", false)
        }
    }
}

final class CodeTextView: NSTextView {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "pdf", "eps"]
    var onSync: (() -> Void)?
    var onDropImages: (([URL]) -> Void)?
    var onPasteImage: ((Data) -> Void)?
    /// Offered every key press first; returns true when the completion list consumed it.
    var onCompletionKey: ((NSEvent) -> Bool)?
    var onResign: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), onCompletionKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func resignFirstResponder() -> Bool { onResign?(); return super.resignFirstResponder() }
    private func imageURLs(on pasteboard: NSPasteboard) -> [URL] {
        ((pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []).filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
    }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + [.fileURL] }
    /// Dropping image files inserts figures at the drop point instead of their paths.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(on: sender.draggingPasteboard)
        guard isEditable, !urls.isEmpty, let onDropImages else { return super.performDragOperation(sender) }
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)), length: 0))
        onDropImages(urls); return true
    }
    /// Pasting a copied image file or bitmap (e.g. a screenshot) inserts a figure.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let urls = imageURLs(on: pasteboard)
        if isEditable, !urls.isEmpty, let onDropImages { onDropImages(urls); return }
        if isEditable, pasteboard.string(forType: .string) == nil, let onPasteImage,
           let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) { onPasteImage(data); return }
        super.paste(sender)
    }
    /// Wraps the selection (or a selected placeholder) in a snippet; undoable as one edit.
    func insertSnippet(before: String, after: String, placeholder: String, block: Bool) {
        guard isEditable else { return }
        let ns = string as NSString; let selection = selectedRange()
        let selected = ns.substring(with: selection)
        var prefix = "", indent = ""
        if block {
            let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            let head = ns.substring(with: NSRange(location: line.location, length: selection.location - line.location))
            indent = String(head.prefix { $0 == " " || $0 == "\t" })
            if !head.trimmingCharacters(in: .whitespaces).isEmpty { prefix = "\n" + indent }
        }
        let body = selected.isEmpty ? placeholder : selected
        let lead = prefix + before.replacingOccurrences(of: "\n", with: "\n" + indent)
        var tail = after.replacingOccurrences(of: "\n", with: "\n" + indent)
        if tail.hasSuffix("\n" + indent) { tail = String(tail.dropLast(indent.count)) }
        insertText(lead + body + tail, replacementRange: selection)
        let target = NSRange(location: selection.location + (lead as NSString).length, length: (body as NSString).length)
        setSelectedRange(target); scrollRangeToVisible(target); window?.makeFirstResponder(self)
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.modifierFlags.contains(.command) { onSync?() }
    }
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let range = ns.lineRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0))
        let current = ns.substring(with: range)
        let indent = String(current.prefix { $0 == " " || $0 == "\t" })
        // Lists continue like a notes app: Return adds the next \item, Return on an empty one ends it.
        let content = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentEnd = NSMaxRange(range) - (current.hasSuffix("\n") ? 1 : 0)
        let atEnd = selectedRange().length == 0 && selectedRange().location >= contentEnd
        if atEnd, content == "\\item" { insertText("", replacementRange: NSRange(location: range.location, length: contentEnd - range.location)); return }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
        if atEnd, content.hasPrefix("\\item") { insertText("\\item ", replacementRange: selectedRange()) }
    }
    override func insertTab(_ sender: Any?) { insertText("  ", replacementRange: selectedRange()) }
    /// The rectangle covering the line(s) that hold the selection, in view coordinates.
    var currentLineRect: NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let ns = string as NSString
        let lines = ns.lineRange(for: NSRange(location: min(selectedRange().location, ns.length), length: min(selectedRange().length, max(0, ns.length - selectedRange().location))))
        var rect: NSRect
        if lines.length == 0 { rect = layoutManager.extraLineFragmentRect; if rect.isEmpty { return nil } }
        else { rect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: lines, actualCharacterRange: nil), in: textContainer) }
        return NSRect(x: 0, y: rect.minY + textContainerInset.height, width: bounds.width, height: rect.height)
    }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let line = currentLineRect { Theme.accent.withAlphaComponent(0.10).setFill(); line.fill(using: .sourceOver) }
        guard let layoutManager, let textContainer, !commentRanges.isEmpty else { return }
        let length = (string as NSString).length, origin = textContainerOrigin
        NSColor.systemYellow.withAlphaComponent(0.28).setFill()
        for range in commentRanges where range.length > 0 && NSMaxRange(range) <= length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                rect.offsetBy(dx: origin.x, dy: origin.y).fill(using: .sourceOver)
            }
        }
    }
    // MARK: Collaboration overlays
    struct RemoteCursor { let offset: Int; let color: NSColor; let name: String }
    /// Carets of collaborators editing this document.
    var remoteCursors: [RemoteCursor] = [] { didSet { needsDisplay = true } }
    /// Text ranges carrying open Overleaf comments.
    var commentRanges: [NSRange] = [] { didSet { needsDisplay = true } }
    private func caretRect(at offset: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let ns = string as NSString; let origin = textContainerOrigin
        var rect: NSRect
        if offset >= ns.length {
            if ns.length == 0 || ns.character(at: ns.length - 1) == 10 { rect = layoutManager.extraLineFragmentRect; rect.size.width = 0 }
            else { rect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: NSRange(location: ns.length - 1, length: 1), actualCharacterRange: nil), in: textContainer); rect.origin.x = rect.maxX; rect.size.width = 0 }
        } else {
            rect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil), in: textContainer); rect.size.width = 0
        }
        guard rect.height > 0 else { return nil }
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for cursor in remoteCursors {
            guard let caret = caretRect(at: cursor.offset), caret.intersects(visibleRect.insetBy(dx: 0, dy: -40)) else { continue }
            cursor.color.setFill(); NSRect(x: caret.minX - 1, y: caret.minY, width: 2, height: caret.height).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor.white]
            let size = (cursor.name as NSString).size(withAttributes: attributes)
            let above = caret.minY - size.height - 2 >= visibleRect.minY
            let tag = NSRect(x: min(caret.minX - 1, bounds.maxX - size.width - 8), y: above ? caret.minY - size.height - 2 : caret.maxY, width: size.width + 8, height: size.height + 2)
            NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
            (cursor.name as NSString).draw(at: NSPoint(x: tag.minX + 4, y: tag.minY + 1), withAttributes: attributes)
        }
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true; enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
}

final class LineRuler: NSRulerView {
    weak var text: CodeTextView?
    /// Lines changed since the last commit, drawn as a coloured strip beside the line numbers.
    var changes: [LineChange] = [] {
        didSet {
            kinds.removeAll()
            for change in changes { for line in change.lines { if kinds[line] == nil || change.kind != .deleted { kinds[line] = change.kind } } }
            deletions = Set(changes.filter { $0.kind == .deleted }.map { $0.lines.lowerBound })
            needsDisplay = true
        }
    }
    /// Lines with a build error (red) or warning (orange); their numbers take that colour.
    var problems: [Int: NSColor] = [:] { didSet { needsDisplay = true } }
    private var kinds: [Int: LineChange.Kind] = [:]
    private var deletions = Set<Int>()
    init(scroll: NSScrollView, text: CodeTextView) {
        self.text = text; super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = text; ruleThickness = 50
    }
    required init(coder: NSCoder) { fatalError() }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.canvas.setFill(); bounds.fill()
        guard let text, let layout = text.layoutManager, let container = text.textContainer, layout.numberOfGlyphs > 0 else { return }
        let visible = text.visibleRect
        let current = text.currentLineRect
        if let current { Theme.accent.withAlphaComponent(0.10).setFill(); NSRect(x: 0, y: current.minY - visible.minY, width: bounds.width, height: current.height).fill(using: .sourceOver) }
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let string = text.string as NSString
        let firstChar = min(layout.characterIndexForGlyph(at: min(glyphs.location, max(0, layout.numberOfGlyphs - 1))), string.length)
        var line = string.substring(to: firstChar).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var glyph = glyphs.location
        while glyph < NSMaxRange(glyphs) {
            var effective = NSRange()
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            let char = layout.characterIndexForGlyph(at: glyph)
            let top = lineRect.minY + text.textContainerInset.height - visible.minY
            if let kind = kinds[line], kind != .deleted {
                (kind == .added ? Theme.green : Theme.accent).setFill()
                NSRect(x: ruleThickness - 7, y: top, width: 3, height: lineRect.height).fill()
            }
            if char == 0 || string.character(at: char - 1) == 10 {
                if deletions.contains(line) {
                    // Removed text leaves a small red wedge at the line it used to precede.
                    let wedge = NSBezierPath(); wedge.move(to: NSPoint(x: ruleThickness - 8, y: top - 4)); wedge.line(to: NSPoint(x: ruleThickness - 2, y: top)); wedge.line(to: NSPoint(x: ruleThickness - 8, y: top + 4)); wedge.close()
                    Theme.red.setFill(); wedge.fill()
                }
                let y = lineRect.minY + text.textContainerInset.height
                let active = current.map { y >= $0.minY - 0.5 && y < $0.maxY - 0.5 } ?? false
                let label = "\(line)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: problems[line] ?? (active ? Theme.text : Theme.lineNumber)]
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 16, y: y - visible.minY + (lineRect.height - size.height) / 2 - 2), withAttributes: attrs)
            }
            let range = layout.characterRange(forGlyphRange: effective, actualGlyphRange: nil)
            if NSMaxRange(range) <= string.length, string.substring(with: range).hasSuffix("\n") { line += 1 }
            guard NSMaxRange(effective) > glyph else { break }; glyph = NSMaxRange(effective)
        }
    }
}

/// A document tab: filled when active, with a file-type tile and a trailing control that
/// shows the unsaved dot and becomes the close button under the pointer.
final class TabChip: NSView {
    private let active: Bool
    private let dirty: Bool
    private var hovering = false { didSet { refresh() } }
    private let close: ActionButton
    private let onSelect: () -> Void
    private let onClose: () -> Void
    init(url: URL, dirty: Bool, active: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.active = active; self.dirty = dirty; self.onSelect = onSelect; self.onClose = onClose
        close = ActionButton("", symbol: "xmark", action: onClose)
        super.init(frame: .zero); wantsLayer = true; layer?.cornerRadius = 8; layer?.cornerCurve = .continuous
        let badge = FileBadge(side: 16); badge.ext = url.pathExtension.lowercased()
        let label = Theme.label(url.lastPathComponent, size: 13, color: active ? Theme.text : Theme.muted, weight: active ? .medium : .regular)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        close.toolTip = "关闭标签  ⌘W"
        let row = NSStackView(views: [badge, label, close]); row.spacing = 7; row.alignment = .centerY; row.setCustomSpacing(3, after: label)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        for constraint in close.constraints { constraint.isActive = false }
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: 16), close.heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 30), widthAnchor.constraint(lessThanOrEqualToConstant: 220)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(url.lastPathComponent)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (active ? Theme.fill : hovering ? Theme.fillSoft : .clear).cgColor
    }
    private func refresh() {
        let showDot = dirty && !hovering
        close.image = Theme.symbol(showDot ? "circle.fill" : "xmark", size: showDot ? 6 : 8, weight: .bold)
        close.contentTintColor = showDot || hovering ? Theme.muted : .clear
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
        if let window { hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onSelect() }
    override func otherMouseDown(with event: NSEvent) { onClose() }
}

/// A whole-file map along the editor's right edge: Git changes on the left half, build
/// problems on the right, and a soft block for the part currently on screen. Clicking jumps there.
final class OverviewRuler: NSView {
    struct Mark { let line: Int; let color: NSColor; let problem: Bool }
    weak var text: CodeTextView?
    var marks: [Mark] = [] { didSet { reposition() } }
    var onJump: ((CGFloat) -> Void)?
    private var positions: [(fraction: CGFloat, mark: Mark)] = []
    override var isFlipped: Bool { true }
    /// Places each mark where its line sits in the laid-out text, so it lines up with the scroller.
    func reposition() {
        positions = []
        defer { needsDisplay = true }
        guard let text, let layout = text.layoutManager, !marks.isEmpty else { return }
        let string = text.string as NSString; let height = max(1, text.bounds.height)
        var starts: [Int: Int] = [:]; let wanted = Set(marks.map(\.line))
        var line = 1, index = 0
        if wanted.contains(1) { starts[1] = 0 }
        while index < string.length, starts.count < wanted.count {
            let newline = string.range(of: "\n", range: NSRange(location: index, length: string.length - index))
            if newline.location == NSNotFound { break }
            index = NSMaxRange(newline); line += 1
            if wanted.contains(line) { starts[line] = index }
        }
        let lineCount = CGFloat(max(1, line))
        for mark in marks {
            guard let start = starts[mark.line] else { continue }
            var fraction = CGFloat(mark.line - 1) / lineCount
            if start < string.length, layout.numberOfGlyphs > 0 {
                let glyph = layout.glyphIndexForCharacter(at: start)
                fraction = (layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + text.textContainerInset.height) / height
            } else if start >= string.length { fraction = 1 }
            positions.append((min(1, max(0, fraction)), mark))
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill(); bounds.fill()
        Theme.hairline.setFill(); NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        if let text, text.bounds.height > 0 {
            let visible = text.visibleRect
            let top = visible.minY / text.bounds.height * bounds.height, size = max(12, visible.height / text.bounds.height * bounds.height)
            if visible.height < text.bounds.height { Theme.fill.setFill(); NSRect(x: 1, y: min(top, bounds.height - size), width: bounds.width - 1, height: size).fill() }
        }
        let half = (bounds.width - 3) / 2
        for (fraction, mark) in positions {
            let y = min(bounds.height - 3, max(0, fraction * bounds.height - 1))
            mark.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: mark.problem ? 2 + half : 2, y: y, width: half - 1, height: mark.problem ? 4 : 3), xRadius: 1, yRadius: 1).fill()
        }
    }
    override func mouseDown(with event: NSEvent) { jump(event) }
    override func mouseDragged(with event: NSEvent) { jump(event) }
    private func jump(_ event: NSEvent) {
        guard bounds.height > 0 else { return }
        onJump?(min(1, max(0, convert(event.locationInWindow, from: nil).y / bounds.height)))
    }
}

/// The quick-insert row. Buttons that do not fit move into a trailing "more" menu instead
/// of being cut off by the neighbouring pane.
final class InsertToolbar: NSView {
    private let entries: [(Snippet, ActionButton)]
    private let onInsert: (Snippet) -> Void
    private var more: ActionButton!
    private var overflow: [Snippet] = []
    init(_ entries: [(Snippet, ActionButton)], onInsert: @escaping (Snippet) -> Void) {
        self.entries = entries; self.onInsert = onInsert
        super.init(frame: .zero)
        more = ActionButton("更多", symbol: "chevron.down", style: .tool) { [weak self] in self?.showMore() }
        more.toolTip = "更多插入命令"; more.imagePosition = .imageTrailing
        for view in entries.map(\.1) + [more!] { view.translatesAutoresizingMaskIntoConstraints = true; addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let spacing: CGFloat = 6, inset: CGFloat = 10
        let sizes = entries.map { $0.1.fittingSize }, moreSize = more.fittingSize
        let total = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
        let fitsAll = total <= bounds.width - inset * 2
        let limit = bounds.width - inset * 2 - (fitsAll ? 0 : moreSize.width + spacing)
        var x = inset; overflow = []
        for (index, entry) in entries.enumerated() {
            let size = sizes[index]
            // Once one button is dropped, the rest follow so the order stays intact.
            if !overflow.isEmpty || x + size.width > inset + limit { entry.1.isHidden = true; overflow.append(entry.0); continue }
            entry.1.isHidden = false; entry.1.frame = NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + spacing
        }
        more.isHidden = overflow.isEmpty
        more.frame = NSRect(x: x, y: (bounds.height - moreSize.height) / 2, width: moreSize.width, height: moreSize.height)
    }
    private func showMore() {
        let menu = NSMenu()
        for snippet in overflow { menu.addItem(ClosureMenuItem(snippet.title, symbol: snippet.symbol) { [weak self] in self?.onInsert(snippet) }) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 6), in: more)
    }
}

final class EditorPane: Surface, NSTextViewDelegate {
    let textView = CodeTextView(frame: .zero)
    let scroll = NSScrollView()
    let tabs = Surface()
    let tabStack = NSStackView()
    private let crumbFile = Theme.label("", size: 12, color: Theme.muted)
    private let crumbArrow = NSImageView()
    private let crumbSection = Theme.label("", size: 12)
    private var highlighting: DispatchWorkItem?
    private var outlining: DispatchWorkItem?
    private var loading = false
    var onChange: ((String) -> Void)?
    var onSelection: ((Int, Int) -> Void)?
    var onSelectTab: ((URL) -> Void)?
    var onCloseTab: ((URL) -> Void)?
    var onOutline: (([OutlineItem]) -> Void)?
    var onInsertImage: (() -> Void)?
    private let insertBar = Surface()
    private let overview = OverviewRuler()
    /// Supplies candidates for what is being typed; nil turns completion off.
    var completions: ((CompletionRequest) -> [CompletionItem])?
    private let popup = CompletionPopup()
    private var completionRequest: CompletionRequest?
    private var completionCursor = -1
    private var completionPaused = false
    private var completionPending = false
    private var gitChanges: [LineChange] = []
    private var problemLines: [(line: Int, error: Bool)] = []
    private var overviewJob: DispatchWorkItem?
    var lineColumn: (Int, Int) {
        let ns = textView.string as NSString; let position = min(textView.selectedRange().location, ns.length)
        let prefix = ns.substring(to: position)
        let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let range = ns.lineRange(for: NSRange(location: position, length: 0))
        return (line, position - range.location + 1)
    }
    override init(frame: NSRect) {
        super.init(frame: frame); lineColor = Theme.line; trailingLine = true
        tabs.fill = Theme.canvas; tabs.bottomLine = true
        tabs.translatesAutoresizingMaskIntoConstraints = false; addSubview(tabs)
        tabStack.orientation = .horizontal; tabStack.spacing = 6; tabStack.alignment = .centerY
        tabStack.translatesAutoresizingMaskIntoConstraints = false; tabs.addSubview(tabStack)
        crumbArrow.image = Theme.symbol("chevron.right", size: 8, weight: .bold); crumbArrow.contentTintColor = Theme.muted
        let crumbs = NSStackView(views: [crumbFile, crumbArrow, crumbSection]); crumbs.spacing = 5; crumbs.alignment = .centerY
        crumbs.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        crumbFile.setContentCompressionResistancePriority(.init(200), for: .horizontal); crumbSection.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        crumbSection.lineBreakMode = .byTruncatingTail
        crumbs.translatesAutoresizingMaskIntoConstraints = false; tabs.addSubview(crumbs)
        // Quick-insert bar
        insertBar.fill = Theme.canvas; insertBar.bottomLine = true
        let tools = InsertToolbar(Snippet.allCases.map { snippet in
            let button = ActionButton(snippet.title, symbol: snippet.symbol, style: .tool) { [weak self] in self?.insert(snippet) }
            button.toolTip = snippet.help; return (snippet, button)
        }) { [weak self] in self?.insert($0) }
        insertBar.pin(tools); insertBar.translatesAutoresizingMaskIntoConstraints = false; addSubview(insertBar)
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        popup.onAccept = { [weak self] in self?.acceptCompletion($0) }
        textView.onResign = { [weak self] in self?.popup.dismiss() }
        textView.onCompletionKey = { [weak self] event in
            guard let self, self.popup.isVisible else { return false }
            switch event.keyCode {
            case 125: self.popup.move(1); return true
            case 126: self.popup.move(-1); return true
            case 36, 76, 48: if let item = self.popup.selected { self.acceptCompletion(item); return true }; return false
            case 53: self.popup.dismiss(); return true
            default: return false
            }
        }
        overview.text = textView; overview.translatesAutoresizingMaskIntoConstraints = false; addSubview(overview)
        overview.toolTip = "全文概览：蓝 / 绿 / 红为 Git 改动，右侧红 / 橙为编译错误与警告；点按跳转"
        overview.onJump = { [weak self] fraction in
            guard let self else { return }
            let height = self.textView.bounds.height, visible = self.scroll.contentView.bounds.height
            self.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(height - visible, fraction * height - visible / 2)))); self.scroll.reflectScrolledClipView(self.scroll.contentView)
        }
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.drawsBackground = false
        textView.minSize = NSSize(width: 0, height: 0); textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 12); textView.textContainer?.lineFragmentPadding = 2
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.isRichText = false; textView.allowsUndo = true; textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false; textView.isGrammarCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        if #available(macOS 15.0, *) { textView.writingToolsBehavior = .none }
        textView.delegate = self
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 22; paragraph.maximumLineHeight = 22
        textView.defaultParagraphStyle = paragraph; textView.typingAttributes[.paragraphStyle] = paragraph
        textView.typingAttributes[.baselineOffset] = 3
        scroll.documentView = textView
        scroll.verticalRulerView = LineRuler(scroll: scroll, text: textView)
        scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: topAnchor), tabs.leadingAnchor.constraint(equalTo: leadingAnchor), tabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), tabs.heightAnchor.constraint(equalToConstant: 46),
            tabStack.leadingAnchor.constraint(equalTo: tabs.leadingAnchor, constant: 10), tabStack.centerYAnchor.constraint(equalTo: tabs.centerYAnchor), tabStack.trailingAnchor.constraint(lessThanOrEqualTo: crumbs.leadingAnchor, constant: -12),
            crumbs.trailingAnchor.constraint(equalTo: tabs.trailingAnchor, constant: -14), crumbs.centerYAnchor.constraint(equalTo: tabs.centerYAnchor), crumbs.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            insertBar.topAnchor.constraint(equalTo: tabs.bottomAnchor), insertBar.leadingAnchor.constraint(equalTo: leadingAnchor), insertBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), insertBar.heightAnchor.constraint(equalToConstant: 40),
            scroll.topAnchor.constraint(equalTo: insertBar.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: overview.leadingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            overview.topAnchor.constraint(equalTo: insertBar.bottomAnchor), overview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), overview.bottomAnchor.constraint(equalTo: bottomAnchor), overview.widthAnchor.constraint(equalToConstant: 14)
        ])
        setBreadcrumb(file: "", section: nil)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    func updateColors() {
        textView.backgroundColor = Theme.canvas; textView.textColor = Theme.code; textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.3)]
        highlight()
    }
    func insert(_ snippet: Snippet) {
        guard textView.isEditable else { return }
        if snippet == .image { onInsertImage?(); return }
        let template = snippet.template
        textView.insertSnippet(before: template.before, after: template.after, placeholder: template.placeholder, block: template.block)
    }
    /// Inserts a figure environment for an image path relative to the main document.
    func insertFigure(path: String, label: String) {
        textView.insertSnippet(before: "\\begin{figure}[htbp]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{\(path)}\n  \\caption{", after: "}\n  \\label{fig:\(label)}\n\\end{figure}\n", placeholder: "图注", block: true)
    }
    /// Adds \usepackage{graphicx} after \documentclass when this file is a main document
    /// that does not load it yet. Returns nil when the file has no preamble to edit.
    func ensureGraphicx() -> Bool? {
        let ns = textView.string as NSString
        if ns.range(of: "graphicx").location != NSNotFound { return false }
        let documentClass = ns.range(of: "\\documentclass")
        guard documentClass.location != NSNotFound else { return nil }
        let line = ns.lineRange(for: documentClass); let selection = textView.selectedRange()
        let addition = "\\usepackage{graphicx}\n" + (ns.substring(with: line).hasSuffix("\n") ? "" : "")
        let prefix = ns.substring(with: line).hasSuffix("\n") ? "" : "\n"
        textView.insertText(prefix + addition, replacementRange: NSRange(location: NSMaxRange(line), length: 0))
        let shift = ((prefix + addition) as NSString).length
        textView.setSelectedRange(NSRange(location: selection.location + (selection.location >= NSMaxRange(line) ? shift : 0), length: selection.length))
        return true
    }
    func setBreadcrumb(file: String? = nil, section: String?) {
        if let file { crumbFile.stringValue = file }
        crumbSection.stringValue = section ?? ""; crumbSection.isHidden = section == nil; crumbArrow.isHidden = section == nil
    }
    /// Applies the fixed line height to the whole buffer; plain-text edits inherit it.
    private func applyParagraphStyle() {
        guard let storage = textView.textStorage, let paragraph = textView.defaultParagraphStyle else { return }
        storage.addAttributes([.paragraphStyle: paragraph, .baselineOffset: 3], range: NSRange(location: 0, length: storage.length))
    }
    func load(_ buffer: EditorBuffer, project: URL) {
        popup.dismiss()
        loading = true; textView.string = buffer.text; applyParagraphStyle(); textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: min(buffer.selection.location, (buffer.text as NSString).length), length: 0))
        setBreadcrumb(file: buffer.url.lastPathComponent, section: nil)
        loading = false; highlight(); scroll.verticalRulerView?.needsDisplay = true; scheduleOverview()
        onOutline?(OutlineItem.parse(buffer.text))
    }
    // MARK: Completion
    private func updateCompletion() {
        let selection = textView.selectedRange()
        guard !completionPaused, let completions, let window, window.firstResponder === textView, !textView.hasMarkedText(), selection.length == 0,
              let request = CompletionRequest.detect(in: textView.string, cursor: selection.location) else { popup.dismiss(); return }
        let items = completions(request)
        guard !items.isEmpty else { popup.dismiss(); return }
        completionRequest = request; completionCursor = selection.location
        popup.show(items, at: textView.firstRect(forCharacterRange: NSRange(location: request.range.location, length: 0), actualRange: nil), in: window)
    }
    private func acceptCompletion(_ item: CompletionItem) {
        guard let request = completionRequest else { return }
        popup.dismiss()
        let edit = Completer.apply(item, to: request, in: textView.string)
        completionPaused = true
        textView.insertText(edit.replacement, replacementRange: edit.range)
        textView.setSelectedRange(NSRange(location: edit.caret, length: 0))
        completionPaused = false; completionCursor = edit.caret
        // A snippet that leaves the caret inside braces may have more to offer (\cite{ → keys).
        if request.kind == .command, item.caret != nil { updateCompletion() }
    }

    /// Replaces only the changed span so the caret, scroll position and undo history survive
    /// edits arriving from collaborators.
    func applyRemote(_ text: String) {
        let ops = OverleafText.splice(from: textView.string, to: text)
        guard let first = ops.first else { return }
        let removed = ops.first { $0.kind == .delete }?.length ?? 0
        let inserted = ops.first { $0.kind == .insert }?.text ?? ""
        let selection = textView.selectedRange()
        guard textView.isEditable else { loading = true; textView.string = text; loading = false; highlight(); onChange?(text); return }
        let origin = scroll.contentView.bounds.origin
        completionPaused = true; defer { completionPaused = false }
        textView.insertText(inserted, replacementRange: NSRange(location: first.position, length: removed))
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        let start = OverleafText.shift(selection.location, by: ops), end = OverleafText.shift(NSMaxRange(selection), by: ops)
        textView.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
    }
    /// Marks lines that differ from the last Git commit.
    func setGitChanges(_ changes: [LineChange]) { (scroll.verticalRulerView as? LineRuler)?.changes = changes; gitChanges = changes; updateOverview() }
    /// Marks lines the last build complained about, in the gutter and in the overview.
    func setProblems(errors: Set<Int>, warnings: Set<Int>) {
        problemLines = warnings.subtracting(errors).map { ($0, false) } + errors.map { ($0, true) }
        var colors: [Int: NSColor] = [:]
        for line in warnings { colors[line] = Theme.orange }
        for line in errors { colors[line] = Theme.red }
        (scroll.verticalRulerView as? LineRuler)?.problems = colors; updateOverview()
    }
    private func updateOverview() {
        var marks: [OverviewRuler.Mark] = []
        for change in gitChanges {
            let color = change.kind == .added ? Theme.green : change.kind == .modified ? Theme.accent : Theme.red
            // Long runs are sampled so one big change does not turn into thousands of marks.
            for line in stride(from: change.lines.lowerBound, through: change.lines.upperBound, by: max(1, change.lines.count / 40)) { marks.append(.init(line: line, color: color, problem: false)) }
        }
        for problem in problemLines { marks.append(.init(line: problem.line, color: problem.error ? Theme.red : Theme.orange, problem: true)) }
        overview.marks = marks
    }
    private func scheduleOverview() {
        overviewJob?.cancel(); let job = DispatchWorkItem { [weak self] in self?.overview.reposition() }; overviewJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: job)
    }
    override func layout() { super.layout(); scheduleOverview() }
    func clear() {
        textView.remoteCursors = []; textView.commentRanges = []; setGitChanges([]); setProblems(errors: [], warnings: [])
        loading = true; textView.string = ""; loading = false
        setBreadcrumb(file: "", section: nil); onOutline?([])
    }
    func updateTabs(_ buffers: [EditorBuffer], active: URL?) {
        tabStack.arrangedSubviews.forEach { tabStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for buffer in buffers {
            let chip = TabChip(url: buffer.url, dirty: buffer.dirty, active: buffer.url == active,
                               onSelect: { [weak self] in self?.onSelectTab?(buffer.url) }, onClose: { [weak self] in self?.onCloseTab?(buffer.url) })
            chip.toolTip = buffer.url.path; tabStack.addArrangedSubview(chip)
        }
    }
    func textDidChange(_ notification: Notification) {
        guard !loading else { return }
        onChange?(textView.string); scheduleHighlight(); scroll.verticalRulerView?.needsDisplay = true; scheduleOverview()
        // Run after the caret has settled too: typing moves it before this call, other input paths after.
        completionPending = true
        DispatchQueue.main.async { [weak self] in self?.completionPending = false; self?.updateCompletion() }
        outlining?.cancel(); let job = DispatchWorkItem { [weak self] in guard let self else { return }; self.onOutline?(OutlineItem.parse(self.textView.string)) }
        outlining = job; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: job)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !loading else { return }; let (line, col) = lineColumn; onSelection?(line, col)
        // Moving the caret without typing closes the list; typing updates `completionCursor` first.
        if popup.isVisible { DispatchQueue.main.async { [weak self] in if let self, !self.completionPending, self.textView.selectedRange().location != self.completionCursor { self.popup.dismiss() } } }
    }
    @objc func scrolled() { popup.dismiss(); scheduleHighlight(); scroll.verticalRulerView?.needsDisplay = true; overview.needsDisplay = true }
    func scheduleHighlight() {
        highlighting?.cancel(); let job = DispatchWorkItem { [weak self] in self?.highlight() }; highlighting = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: job)
    }
    private static let patterns: [(NSRegularExpression, NSColor)] = [
        ("\\\\[a-zA-Z@]+\\*?|\\\\[^a-zA-Z]", Theme.command), ("\\[[^\\]\\n]*\\]", Theme.option), ("[{}]", Theme.brace),
        ("(?<=\\\\begin\\{|\\\\end\\{)[^}\\n]*", Theme.environment), ("(?<!\\\\)%[^\\n]*", Theme.comment)
    ].compactMap { pattern, color in (try? NSRegularExpression(pattern: pattern)).map { ($0, color) } }
    func highlight() {
        guard let storage = textView.textStorage, let layout = textView.layoutManager, let container = textView.textContainer, storage.length > 0 else { return }
        let glyph = layout.glyphRange(forBoundingRect: textView.visibleRect.insetBy(dx: 0, dy: -300), in: container)
        let visible = layout.characterRange(forGlyphRange: glyph, actualGlyphRange: nil)
        let ns = textView.string as NSString
        let range = ns.lineRange(for: NSIntersectionRange(visible, NSRange(location: 0, length: ns.length)))
        guard range.length < 100_000 else { return }
        // Temporary layout attributes do not affect undo history or saved document formatting.
        layout.addTemporaryAttribute(.foregroundColor, value: Theme.code, forCharacterRange: range)
        for (regex, color) in Self.patterns {
            for match in regex.matches(in: textView.string, range: range) { layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: match.range) }
        }
    }
    func goTo(line: Int, column: Int = 0) {
        let ns = textView.string as NSString; var location = 0
        for _ in 1..<max(1, line) { if location >= ns.length { break }; location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0))) }
        let range = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        let target = NSRange(location: min(range.location + max(0, column), NSMaxRange(range)), length: 0)
        textView.setSelectedRange(target); textView.scrollRangeToVisible(target); textView.showFindIndicator(for: range)
        window?.makeFirstResponder(textView)
    }
}
