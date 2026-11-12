import AppKit
import BetterTeXCore

/// A compact remaining-quota bar, sharing the context row rather than adding another row.
final class QuotaUsageBar: NSButton {
    var remainingFraction: Double? { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; setButtonType(.momentaryChange)
        size(112, 28)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let trackRect = NSRect(x: 4, y: 3, width: bounds.width - 8, height: 4)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2)
        Theme.fill.setFill(); track.fill()
        if let fraction = remainingFraction {
            let value = min(1, max(0, fraction))
            if value > 0 {
                NSGraphicsContext.saveGraphicsState(); track.addClip()
                let fill = NSBezierPath(roundedRect: NSRect(x: trackRect.minX, y: trackRect.minY, width: trackRect.width * value, height: trackRect.height), xRadius: 2, yRadius: 2)
                (value <= 0.1 ? Theme.red : value <= 0.25 ? Theme.orange : Theme.accent).setFill(); fill.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        } else {
            // A dashed neutral track distinguishes unreported quota from a real zero.
            let unknown = NSBezierPath()
            unknown.move(to: NSPoint(x: trackRect.minX + 2, y: trackRect.midY))
            unknown.line(to: NSPoint(x: trackRect.maxX - 2, y: trackRect.midY))
            unknown.lineWidth = 1; unknown.setLineDash([2, 3], count: 2, phase: 0)
            Theme.muted.withAlphaComponent(0.35).setStroke(); unknown.stroke()
        }
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: Theme.muted, .paragraphStyle: style]
        (title as NSString).draw(in: NSRect(x: 4, y: 11, width: bounds.width - 8, height: 13), withAttributes: attributes)
    }
}

/// A small, accessible ring in the existing composer context row.
final class ContextUsageRing: NSButton {
    var usage: AgentContextUsage? { didSet { updateLabel(); needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; title = ""; setButtonType(.momentaryChange)
        size(28, 28); updateLabel()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func updateLabel() {
        let label = usage?.fraction.map { L10n.tr("上下文已用 \(Int(($0 * 100).rounded()))%") } ?? L10n.tr("上下文用量尚未获取")
        toolTip = label; setAccessibilityLabel(label)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3, dy: 3), track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 2.5; Theme.fill.setStroke(); track.stroke()
        let fraction = usage?.fraction
        if let fraction, fraction > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2,
                          startAngle: 90, endAngle: 90 - CGFloat(fraction) * 360, clockwise: true)
            arc.lineWidth = 2.5; arc.lineCapStyle = .round
            (fraction >= 0.9 ? Theme.red : fraction >= 0.75 ? Theme.orange : Theme.accent).setStroke(); arc.stroke()
        }
        let value = fraction.map { String(Int(($0 * 100).rounded())) } ?? "—"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium), .foregroundColor: Theme.muted]
        let size = (value as NSString).size(withAttributes: attributes)
        (value as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

/// Quota remaining and context used stay distinct; details appear only on demand.
final class AgentUsageView: NSStackView {
    let ring = ContextUsageRing(frame: .zero)
    let quotaButton = QuotaUsageBar(frame: .zero)
    var onRefresh: (() -> Void)?
    private var provider: AgentProvider = .codex
    private var quota: AgentQuotaSnapshot?
    private var refreshing = false
    private var failed = false
    override init(frame: NSRect) {
        super.init(frame: frame); orientation = .horizontal; alignment = .centerY; spacing = 6
        quotaButton.target = self; quotaButton.action = #selector(quotaClicked)
        ring.target = self; ring.action = #selector(ringClicked)
        addArrangedSubview(quotaButton); addArrangedSubview(ring)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        update(provider: .codex, context: nil, quota: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(provider: AgentProvider, context: AgentContextUsage?, quota: AgentQuotaSnapshot?, refreshing: Bool = false, failed: Bool = false, now: Date = Date()) {
        self.provider = provider; self.quota = quota; self.refreshing = refreshing; self.failed = failed; ring.usage = context
        let title: String
        if let remaining = quota?.remainingPercent(at: now) { title = L10n.tr("额度剩余 \(Int(remaining.rounded(.down)))%") }
        else if refreshing { title = L10n.tr("额度刷新中…") }
        else if let quota, !quota.isCurrent(at: now) { title = L10n.tr("额度待刷新") }
        else if quota?.status == "rejected" || quota?.status == "credits_required" { title = L10n.tr("额度受限") }
        else { title = L10n.tr("额度 —") }
        quotaButton.title = title
        quotaButton.remainingFraction = quota?.remainingPercent(at: now).map { $0 / 100 }
        quotaButton.toolTip = title + " · " + L10n.tr("查看额度周期、重置时间与上下文用量")
        quotaButton.setAccessibilityLabel(title)
    }
    @objc private func quotaClicked() { showDetails(from: quotaButton) }
    @objc private func ringClicked() { showDetails(from: ring) }
    private func showDetails(from button: NSButton?) {
        guard let button else { return }
        let menu = detailsMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -(menu.size.height + 6)), in: button)
    }
    func detailsMenu(now: Date = Date()) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func row(_ text: String) { let item = NSMenuItem(title: text, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        row(L10n.tr("\(provider.rawValue) 使用情况"))
        menu.addItem(.separator())
        if let context = ring.usage, let used = context.usedTokens {
            if let limit = context.limitTokens { row(L10n.tr("上下文：\(used.formatted()) / \(limit.formatted()) tokens")) }
            else { row(L10n.tr("上下文：\(used.formatted()) tokens · 容量未知")) }
            if let model = context.model { row(model) }
            row(L10n.tr("最近一次请求的上下文，非累计用量"))
        } else { row(L10n.tr("上下文用量尚未获取")) }
        menu.addItem(.separator())
        if let quota {
            let stale = now.timeIntervalSince(quota.observedAt) >= 300
            for window in quota.windows {
                if let remaining = window.remainingPercent(at: now), !stale {
                    row(window.title + " · " + L10n.tr("剩余 \(Int(remaining.rounded(.down)))%"))
                } else { row(window.title + " · " + L10n.tr("待刷新")) }
                if let reset = window.resetsAt { row(L10n.tr("重置时间：\(Self.date(reset))")) }
            }
            if quota.isCurrent(at: now) {
                if quota.status == "rejected" || quota.status == "credits_required" { row(L10n.tr("额度受限")) }
                else if quota.status == "allowed_warning" { row(L10n.tr("额度接近上限")) }
            }
            if let plan = quota.plan { row(L10n.tr("套餐：\(plan)")) }
            row(L10n.tr("更新于 \(Self.date(quota.observedAt))"))
        } else { row(L10n.tr("额度尚未获取")) }
        if failed { row(L10n.tr("额度刷新失败，稍后重试")) }
        if provider == .claude { row(L10n.tr("Claude 在会话响应中更新用量；未上报的额度无法显示")) }
        else {
            menu.addItem(.separator())
            let refresh = ClosureMenuItem(refreshing ? L10n.tr("额度刷新中…") : L10n.tr("刷新用量")) { [weak self] in self?.onRefresh?() }
            refresh.isEnabled = !refreshing; menu.addItem(refresh)
        }
        return menu
    }
    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale; formatter.dateStyle = .short; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
