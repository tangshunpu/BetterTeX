import AppKit
import XCTest
import BetterTeXCore
@testable import BetterTeX

final class UpdatePresentationTests: XCTestCase {
    @MainActor func testAutomaticNoticePreservesEditorFocusAndReturnInput() async throws {
        let app = NSApplication.shared
        guard app.isActive else { throw XCTSkip("Focus verification requires an active macOS GUI test host.") }
        let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        editorWindow.isReleasedWhenClosed = false
        let editor = NSTextView(frame: editorWindow.contentView!.bounds)
        editorWindow.contentView = editor
        editorWindow.makeKeyAndOrderFront(nil); editorWindow.makeFirstResponder(editor)
        defer { editorWindow.close() }
        XCTAssertTrue(editorWindow.isKeyWindow)

        let controller = UpdateController()
        let existing = Set(app.windows.map(\.windowNumber))
        controller.present(try release(), userInitiated: false)
        let prompt = try XCTUnwrap(app.windows.first { !existing.contains($0.windowNumber) })
        defer { prompt.close(); controller.stop() }
        XCTAssertTrue(prompt.isVisible)
        XCTAssertFalse(prompt.isKeyWindow)
        XCTAssertTrue(editorWindow.isKeyWindow)
        XCTAssertTrue(editorWindow.firstResponder === editor)

        let button = try installButton(in: prompt)
        let clicks = ClickRecorder(); button.target = clicks; button.action = #selector(ClickRecorder.clicked)
        let event = try returnEvent(for: editorWindow)
        let keyWindow = try XCTUnwrap(app.keyWindow)
        if !keyWindow.performKeyEquivalent(with: event) { keyWindow.sendEvent(event) }
        XCTAssertEqual(editor.string, "\n")
        XCTAssertEqual(clicks.count, 0)

        // A manual check can bring that same notice forward without duplicating it.
        controller.present(try release(), userInitiated: true)
        XCTAssertTrue(prompt.isKeyWindow)
    }

    @MainActor func testReturnDoesNotTriggerInstallButClickDoes() async throws {
        let app = NSApplication.shared, controller = UpdateController()
        let existing = Set(app.windows.map(\.windowNumber))
        controller.present(try release(), userInitiated: true)
        let prompt = try XCTUnwrap(app.windows.first { !existing.contains($0.windowNumber) })
        defer { prompt.close(); controller.stop() }
        let button = try installButton(in: prompt)
        let clicks = ClickRecorder(); button.target = clicks; button.action = #selector(ClickRecorder.clicked)
        let event = try returnEvent(for: prompt)
        XCTAssertFalse(prompt.performKeyEquivalent(with: event))
        XCTAssertFalse(button.performKeyEquivalent(with: event))
        XCTAssertEqual(clicks.count, 0)
        button.performClick(nil)
        XCTAssertEqual(clicks.count, 1)
    }

    @MainActor private func installButton(in window: NSWindow) throws -> NSButton {
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        return try XCTUnwrap(buttons(in: XCTUnwrap(window.contentView)).first { $0.title == L10n.tr("下载并安装") })
    }
    @MainActor private func returnEvent(for window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\r",
                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }
    private func release() throws -> AppRelease {
        let name = "BetterTeX-99.0.0-macOS-\(AppUpdateClient.architecture).zip"
        let assets: [[String: Any]] = [name, name + ".sig"].map {
            ["name": $0, "browser_download_url": "https://github.com/tangshunpu/BetterTeX/releases/download/v99.0.0/" + $0,
             "size": 100, "digest": "sha256:" + String(repeating: "a", count: 64)]
        }
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v99.0.0", "draft": false, "prerelease": false, "assets": assets])
        return try JSONDecoder().decode(AppRelease.self, from: data)
    }
}

@MainActor private final class ClickRecorder: NSObject {
    var count = 0
    @objc func clicked() { count += 1 }
}
