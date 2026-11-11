import AppKit
import WebKit
import BetterTeXCore

/// The only web view in BetterTeX: a sign-in window whose sole purpose is to obtain Overleaf's
/// session cookies. Once signed in it closes; everything else talks to Overleaf natively.
final class OverleafLogin: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private static var current: OverleafLogin?
    private let host: URL
    private let window: NSWindow
    private let webView: WKWebView
    private var continuation: CheckedContinuation<[HTTPCookie], Error>?

    private static var cookieStore: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }
    private static func matches(_ cookie: HTTPCookie, _ host: URL) -> Bool {
        guard let name = host.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name == domain || name.hasSuffix("." + domain)
    }
    /// Cookies kept from an earlier sign-in. No web view is created.
    @MainActor static func storedCookies(host: URL) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in continuation.resume(returning: cookies.filter { matches($0, host) }) }
        }
    }
    /// Writes cookies refreshed by the server back, so the session survives restarts.
    static func store(_ cookies: [HTTPCookie]) { for cookie in cookies { cookieStore.setCookie(cookie) } }
    @MainActor static func clear(host: URL) async {
        for cookie in await storedCookies(host: host) { await withCheckedContinuation { done in cookieStore.delete(cookie) { done.resume() } } }
    }

    /// Shows the sign-in window and returns the session cookies once the dashboard is reached.
    @MainActor static func present(host: URL) async throws -> [HTTPCookie] {
        if let current { current.window.makeKeyAndOrderFront(nil); throw OverleafError.message("请先在已打开的窗口中完成 Overleaf 登录。") }
        let login = OverleafLogin(host: host); current = login
        defer { current = nil }
        return try await withCheckedThrowingContinuation { continuation in login.start(continuation) }
    }

    private init(host: URL) {
        self.host = host
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: WKWebViewConfiguration())
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        webView.customUserAgent = OverleafClient.userAgent; webView.navigationDelegate = self; webView.uiDelegate = self
        window.title = "登录 Overleaf · \(host.host ?? "")"; window.contentView = webView; window.isReleasedWhenClosed = false; window.delegate = self; window.center()
    }
    private func start(_ continuation: CheckedContinuation<[HTTPCookie], Error>) {
        self.continuation = continuation
        webView.load(URLRequest(url: host.appendingPathComponent("login")))
        window.makeKeyAndOrderFront(nil)
    }
    private func finish(_ result: Result<[HTTPCookie], Error>) {
        guard let continuation else { return }
        self.continuation = nil; webView.stopLoading(); window.orderOut(nil); continuation.resume(with: result)
    }
    private func check() {
        // Reaching the project dashboard means the session cookie is in place.
        guard continuation != nil, let url = webView.url, url.host == host.host, url.path.lowercased().hasPrefix("/project") else { return }
        Self.cookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            self.finish(.success(cookies.filter { Self.matches($0, self.host) }))
        }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { check() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { check() }
    /// Sign-in providers that open a new window continue in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
    func windowWillClose(_ notification: Notification) { finish(.failure(OverleafError.message("已取消 Overleaf 登录。"))) }
}
