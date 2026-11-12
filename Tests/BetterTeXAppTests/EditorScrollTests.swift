import AppKit
import XCTest
@testable import BetterTeX

final class EditorScrollTests: XCTestCase {
    /// Wrapped source text must never slide sideways under the line-number ruler.
    @MainActor func testEditorSnapsBackToItsLeftEdge() {
        _ = NSApplication.shared
        let editor = EditorPane(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        defer { window.close() }
        editor.textView.string = String(repeating: "A long line of LaTeX source that wraps inside the editor. ", count: 400)
        editor.layoutSubtreeIfNeeded()
        let clip = editor.scroll.contentView
        let edge = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: -1_000_000, y: 0), size: clip.bounds.size)).origin.x
        clip.scroll(to: NSPoint(x: edge + 60, y: 200)); editor.scroll.reflectScrolledClipView(clip)
        XCTAssertEqual(clip.bounds.origin.x, edge, accuracy: 0.5)
        XCTAssertEqual(clip.bounds.origin.y, 200, accuracy: 0.5)
    }
}
