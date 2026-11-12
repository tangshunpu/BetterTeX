import AppKit
import XCTest
@testable import BetterTeX

final class ComposerLayoutTests: XCTestCase {
    /// The round send button's frame (which its layer fills) must be square, not padded taller by NSButton.
    @MainActor func testSendButtonIsACircle() {
        _ = NSApplication.shared
        let panel = TerminalPanel(frame: NSRect(x: 0, y: 0, width: 380, height: 680))
        let window = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        defer { panel.stopAll(); window.close() }
        panel.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let send = try? XCTUnwrap(all(panel).compactMap { $0 as? ActionButton }.first { $0.style == .send })
        XCTAssertEqual(send?.frame.width ?? 0, 28, accuracy: 0.01)
        XCTAssertEqual(send?.frame.height ?? 0, 28, accuracy: 0.01)
        XCTAssertEqual(send?.layer?.cornerCurve, .circular)
    }
}
