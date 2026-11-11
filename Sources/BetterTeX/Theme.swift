import AppKit

/// The iOS-style palette from the BetterTeX UI design: grouped dark surfaces, translucent
/// grey fills and system tint colours, with light-appearance counterparts.
enum Theme {
    static let accent = NSColor.systemBlue
    static let green = NSColor.systemGreen
    static let orange = NSColor.systemOrange
    static let red = NSColor.systemRed
    static let indigo = adaptive(0x5856D6, 0x5E5CE6)
    // Surfaces
    static let base = adaptive(0xF2F2F7, 0x1C1C1E)
    static let header = adaptive(0xF7F7FA, 0x28282A)
    static let sidebar = adaptive(0xECECF1, 0x252527)
    static let canvas = adaptive(0xFFFFFF, 0x1F1F22)
    static let pdfBack = adaptive(0xE3E3E8, 0x161618)
    static let card = adaptive(0xFFFFFF, 0x2C2C2E)
    static let bar = base
    // Fills and lines
    static let fill = adaptive(0x767680, 0x767680, lightAlpha: 0.13, darkAlpha: 0.24)
    static let fillSoft = adaptive(0x767680, 0x767680, lightAlpha: 0.08, darkAlpha: 0.12)
    static let segment = adaptive(0xFFFFFF, 0x636366)
    static let line = adaptive(0x3C3C43, 0x000000, lightAlpha: 0.16, darkAlpha: 0.55)
    static let hairline = adaptive(0x3C3C43, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.07)
    // Text
    static let text = adaptive(0x1C1C1E, 0xF5F5F7)
    static let soft = adaptive(0x3A3A3C, 0xD1D1D6)
    static let muted = adaptive(0x6C6C70, 0x98989F)
    static let faint = adaptive(0x8E8E93, 0x636366)
    // Syntax
    static let command = adaptive(0xAD3DA4, 0xFF7AB2)
    static let option = adaptive(0x78492A, 0xD9C97C)
    static let brace = adaptive(0x6C6C70, 0xA1A1A6)
    static let code = adaptive(0x1C1C1E, 0xE1E1E3)
    static let comment = adaptive(0x707F8C, 0x8E959E)
    static let environment = adaptive(0x03638C, 0xACF2E4)
    static let lineNumber = adaptive(0x8E8E93, 0x8E8E93)

    static func adaptive(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark).withAlphaComponent(darkAlpha) : NSColor(hex: light).withAlphaComponent(lightAlpha)
        }
    }
    static func label(_ text: String, size: CGFloat = 13, color: NSColor = Theme.text, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
    static func symbol(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .medium, description: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
    static func divider(height: CGFloat = 18) -> NSView {
        let view = Chip(fill: Theme.adaptive(0x3C3C43, 0xFFFFFF, lightAlpha: 0.18, darkAlpha: 0.14), radius: 0)
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true; view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

class Surface: NSView {
    var fill: NSColor = Theme.canvas { didSet { needsDisplay = true } }
    var lineColor: NSColor = Theme.hairline
    var bottomLine = false
    var topLine = false
    var trailingLine = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill(); bounds.fill()
        // Separators are translucent, so they must be composited rather than copied.
        lineColor.setFill()
        if bottomLine { NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill(using: .sourceOver) }
        if topLine { NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill(using: .sourceOver) }
        if trailingLine { NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill(using: .sourceOver) }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// A layer-backed rounded rectangle whose colours track the appearance.
class Chip: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat { didSet { needsDisplay = true } }
    init(fill: NSColor? = Theme.fill, radius: CGFloat = 8, border: NSColor? = nil) {
        self.fill = fill; self.radius = radius; self.border = border
        super.init(frame: .zero); wantsLayer = true; layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = radius < 0 ? bounds.height / 2 : radius
        layer?.backgroundColor = fill?.cgColor
        layer?.borderColor = border?.cgColor; layer?.borderWidth = border == nil ? 0 : 1
    }
    override func layout() { super.layout(); if radius < 0 { needsDisplay = true } }
}

extension NSView {
    func pin(_ child: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset), child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: topAnchor, constant: inset), child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
    }
    /// Lays a row out along the horizontal centre of a fixed-height bar.
    func pinRow(_ child: NSView, leading: CGFloat = 10, trailing: CGFloat = 10) {
        child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading), child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailing),
            child.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    func size(_ width: CGFloat? = nil, _ height: CGFloat? = nil) {
        translatesAutoresizingMaskIntoConstraints = false
        if let width { widthAnchor.constraint(equalToConstant: width).isActive = true }
        if let height { heightAnchor.constraint(equalToConstant: height).isActive = true }
    }
}

/// A custom-drawn button in the design's vocabulary.
final class ActionButton: NSButton {
    enum Style {
        case icon      // 30 pt square, grey glyph, soft fill on hover
        case accentIcon // same, tinted glyph
        case chip      // grey filled rounded rectangle with a label
        case plain     // text-only, muted
        case tool      // small soft chip with a leading glyph (quick-insert bar)
        case pill      // accent-filled capsule (primary action)
        case tinted    // accent-tinted capsule (secondary action)
        case circle    // grey filled circle
        case send      // accent filled circle
        case push      // standard system push button
        case prominent // standard default button
    }
    var onClick: (() -> Void)?
    let style: Style
    private var hovering = false { didSet { needsDisplay = true } }
    private var label = ""
    init(_ title: String, symbol: String? = nil, style: Style = .icon, action: @escaping () -> Void) {
        self.style = style
        super.init(frame: .zero); onClick = action; target = self; self.action = #selector(clicked)
        if style == .push || style == .prominent {
            self.title = title; bezelStyle = .rounded; font = .systemFont(ofSize: 13)
            if style == .prominent { keyEquivalent = "\r" }
            return
        }
        isBordered = false; wantsLayer = true; layer?.cornerCurve = .continuous; focusRingType = .none
        setButtonType(.momentaryChange)
        let glyph: CGFloat = style == .pill ? 10 : style == .tool ? 11 : style == .send ? 12 : style == .chip || style == .plain ? 9 : 15
        if let symbol { image = Theme.symbol(symbol, size: glyph, weight: style == .send || style == .pill ? .bold : .medium, description: title) }
        imagePosition = title.isEmpty ? .imageOnly : (style == .chip || style == .plain ? .imageTrailing : .imageLeading)
        imageHugsTitle = true
        setTitle(title)
        switch style {
        case .icon, .accentIcon: size(30, 30)
        case .circle: size(34, 34)
        case .send: size(26, 26)
        case .chip: size(nil, 32)
        case .pill: size(nil, 32)
        case .tinted: size(nil, 30)
        case .plain: size(nil, 26)
        case .tool: size(nil, 28)
        default: break
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private var foreground: NSColor {
        switch style {
        case .icon: return Theme.muted
        case .accentIcon, .tinted: return Theme.accent
        case .chip: return Theme.text
        case .plain: return Theme.muted
        case .pill, .send: return .white
        case .circle, .tool: return Theme.soft
        default: return Theme.text
        }
    }
    func setTitle(_ title: String) {
        label = title
        guard style != .push, style != .prominent else { self.title = title; return }
        imagePosition = title.isEmpty ? .imageOnly : (style == .chip || style == .plain ? .imageTrailing : .imageLeading)
        let weight: NSFont.Weight = style == .pill || style == .tinted ? .semibold : style == .chip ? .medium : .regular
        attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: style == .plain || style == .tool ? 12 : 13, weight: weight), .foregroundColor: foreground])
        contentTintColor = style == .chip || style == .plain ? Theme.muted : foreground
        invalidateIntrinsicContentSize()
    }
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        guard style != .push, style != .prominent, !label.isEmpty else { return size }
        size.width += style == .tool ? 18 : 24
        return size
    }
    override var wantsUpdateLayer: Bool { style != .push && style != .prominent }
    override func updateLayer() {
        let pressed = isHighlighted
        var color: NSColor = .clear
        switch style {
        case .icon, .accentIcon, .plain: color = pressed ? Theme.fill : hovering ? Theme.fillSoft : .clear
        case .chip, .circle: color = Theme.fill
        case .tool: color = pressed || hovering ? Theme.fill : Theme.fillSoft
        case .pill, .send: color = Theme.accent
        case .tinted: color = Theme.accent.withAlphaComponent(0.18)
        default: break
        }
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = style == .pill || style == .tinted || style == .circle || style == .send ? bounds.height / 2 : 8
        layer?.opacity = isEnabled ? (pressed && style != .icon && style != .accentIcon && style != .plain ? 0.7 : (hovering && (style == .pill || style == .send) ? 0.9 : 1)) : 0.4
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var toolTip: String? { didSet { if label.isEmpty, let toolTip { setAccessibilityLabel(toolTip) } } }
    @objc private func clicked() {
        onClick?()
        // A menu opened by the click swallows the mouse-exited event; re-check the pointer afterwards.
        if let window { hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }
}

/// The coloured file-type tile used in the sidebar, tabs and search results.
final class FileBadge: NSView {
    var ext = "" { didSet { needsDisplay = true } }
    /// On an accent-filled row the tile turns translucent white.
    var onAccent = false { didSet { needsDisplay = true } }
    private let side: CGFloat
    init(side: CGFloat = 20) { self.side = side; super.init(frame: .zero); size(side, side) }
    required init?(coder: NSCoder) { fatalError() }
    static func color(for ext: String) -> (NSColor, NSColor) {
        switch ext {
        case "tex", "sty", "cls": return (Theme.indigo, .white)
        case "bib": return (NSColor(hex: 0xFF9F0A), NSColor(hex: 0x1C1C1E))
        case "pdf": return (Theme.red, .white)
        case "png", "jpg", "jpeg", "eps", "svg": return (Theme.green, NSColor(hex: 0x1C1C1E))
        default: return (NSColor(hex: 0x636366), .white)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let (fill, ink) = FileBadge.color(for: ext)
        (onAccent ? NSColor.white.withAlphaComponent(0.22) : fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: side * 0.25, yRadius: side * 0.25).fill()
        let text = String((ext.isEmpty ? "TXT" : ext).uppercased().prefix(3)) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: side * 0.4, weight: .bold), .foregroundColor: onAccent ? NSColor.white : ink]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

/// An iOS-style segmented control: grey track, raised selected segment.
final class SegmentedTabs: NSView {
    let titles: [String]
    var onSelect: ((Int) -> Void)?
    var selected = -1 { didSet { refresh(animated: oldValue >= 0 && selected >= 0) } }
    private let thumb = Chip(fill: Theme.segment, radius: 7)
    private var labels: [NSTextField] = []
    init(_ titles: [String]) {
        self.titles = titles; super.init(frame: .zero)
        let track = Chip(fill: Theme.fill, radius: 9); pin(track)
        thumb.shadow = { let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.16); s.shadowBlurRadius = 4; s.shadowOffset = NSSize(width: 0, height: -2); return s }()
        addSubview(thumb)
        for title in titles {
            let label = Theme.label(title, size: 12, weight: .medium); label.alignment = .center; label.lineBreakMode = .byClipping
            labels.append(label); addSubview(label)
        }
        size(nil, 30); setAccessibilityRole(.tabGroup)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    /// Segments share the width in proportion to their titles, so short titles leave room for long ones.
    private var segmentFrames: [NSRect] {
        let natural = labels.map { $0.intrinsicContentSize.width + 10 }
        let total = max(1, natural.reduce(0, +)), available = bounds.width - 4
        var x: CGFloat = 2
        return natural.map { width in
            let scaled = width / total * available
            defer { x += scaled }
            return NSRect(x: x, y: 2, width: scaled, height: bounds.height - 4)
        }
    }
    private func frame(for index: Int) -> NSRect { let frames = segmentFrames; return frames.indices.contains(index) ? frames[index] : .zero }
    override func layout() {
        super.layout()
        for (index, label) in labels.enumerated() {
            let cell = frame(for: index); let height = label.intrinsicContentSize.height
            label.frame = NSRect(x: cell.minX, y: cell.midY - height / 2, width: cell.width, height: height)
        }
        if selected >= 0 { thumb.frame = frame(for: selected) }
    }
    private func refresh(animated: Bool) {
        thumb.isHidden = selected < 0
        for (index, label) in labels.enumerated() {
            let on = index == selected
            label.font = .systemFont(ofSize: 12, weight: on ? .semibold : .medium)
            label.textColor = on ? Theme.adaptive(0x1C1C1E, 0xFFFFFF) : Theme.text
        }
        guard selected >= 0 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                thumb.animator().frame = frame(for: selected)
            }
        } else { thumb.frame = frame(for: selected) }
    }
    // The whole control is one click target; otherwise the title labels swallow the clicks that land on them.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // AppKit can re-deliver a delayed mouse-down whose location is no longer over the control;
        // without this check such an event would count as a click on the first segment.
        guard bounds.contains(point) else { return }
        let frames = segmentFrames
        let index = frames.firstIndex { point.x < $0.maxX } ?? (titles.count - 1)
        guard index != selected else { return }
        selected = index; onSelect?(index)
    }
}

/// A grouped-list row that highlights under the pointer and fires on click.
final class RowButton: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    init(height: CGFloat, action: @escaping () -> Void) {
        super.init(frame: .zero); onClick = action; wantsLayer = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = (hovering ? Theme.fillSoft : NSColor.clear).cgColor }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
