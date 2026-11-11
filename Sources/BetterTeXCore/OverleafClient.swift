import Foundation

public enum OverleafError: LocalizedError {
    case notLoggedIn
    case http(Int, String)
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Overleaf 登录已失效，请重新登录。"
        case .http(let status, let detail): return "Overleaf 请求失败（HTTP \(status)）" + (detail.isEmpty ? "。" : "：\(detail)")
        case .message(let text): return text
        }
    }
}

public struct OverleafProject: Equatable {
    public let id: String
    public let name: String
    public let accessLevel: String
    /// When the project last changed on Overleaf, if the server says.
    public var lastUpdated: Date? = nil
}

public struct OverleafMessage {
    public let id: String
    public let content: String
    public let author: String
    public let date: Date
}
public struct OverleafThread {
    public let id: String
    public var messages: [OverleafMessage]
    public var resolved: Bool
}

/// Overleaf's web endpoints, called with the session cookies obtained from the sign-in window.
/// Overleaf has no public API; these are the routes its own editor uses.
public final class OverleafClient {
    public static let defaultHost = "https://www.overleaf.com"
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
    public let host: URL
    let session: URLSession
    private var csrf: String?

    public init(host: URL, cookies: [HTTPCookie]) {
        self.host = host
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage?.cookieAcceptPolicy = .always
        for cookie in cookies { configuration.httpCookieStorage?.setCookie(cookie) }
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        configuration.timeoutIntervalForRequest = 45; configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }
    /// The live cookies, including any the server refreshed during this run.
    public var cookies: [HTTPCookie] { session.configuration.httpCookieStorage?.cookies ?? [] }
    var cookieHeader: String { (session.configuration.httpCookieStorage?.cookies(for: host) ?? []).map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var base = host.absoluteString; while base.hasSuffix("/") { base.removeLast() }
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var components = URLComponents(string: base + "/" + escaped)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }

    private func check(_ response: URLResponse, _ data: Data?) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw OverleafError.message("Overleaf 没有响应。") }
        // An expired session is answered with a redirect to the sign-in page.
        if http.url?.path.hasPrefix("/login") == true || http.statusCode == 401 { throw OverleafError.notLoggedIn }
        guard (200..<300).contains(http.statusCode) else {
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let detail = object?["message"] as? String ?? (object?["message"] as? [String: Any])?["text"] as? String ?? object?["error"] as? String ?? ""
            if http.statusCode == 403 && detail.isEmpty { throw OverleafError.http(403, "没有权限，或登录已失效") }
            if http.statusCode == 429 { throw OverleafError.http(429, "请求过于频繁，请稍后再试") }
            throw OverleafError.http(http.statusCode, detail)
        }
        return http
    }

    func token() async throws -> String {
        if let csrf { return csrf }
        var request = URLRequest(url: url("dev/csrf")); request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        _ = try check(response, data)
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count < 200, !token.contains("<") else { throw OverleafError.notLoggedIn }
        csrf = token; return token
    }

    @discardableResult
    func send(_ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil) async throws -> Data {
        func attempt() async throws -> Data {
            var request = URLRequest(url: url(path, query: query)); request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if method != "GET" { request.setValue(try await token(), forHTTPHeaderField: "X-Csrf-Token") }
            if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await session.data(for: request)
            _ = try check(response, data); return data
        }
        do { return try await attempt() }
        catch OverleafError.http(403, _) where method != "GET" { csrf = nil; return try await attempt() }  // stale CSRF token
    }
    private func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    // MARK: Projects
    public func projects() async throws -> [OverleafProject] {
        // The dashboard endpoint knows when each project last changed; older servers only have the plain list.
        if let data = try? await send("POST", "api/project", json: ["filters": [String: Any](), "page": ["size": 2000], "sort": ["by": "lastUpdated", "order": "desc"]]),
           let list = object(data)["projects"] as? [[String: Any]], !list.isEmpty {
            let detailed = list.filter { $0["trashed"] as? Bool != true && $0["archived"] as? Bool != true }.compactMap(Self.project)
            if !detailed.isEmpty { return detailed }
        }
        let data = try await send("GET", "user/projects")
        guard let list = object(data)["projects"] as? [[String: Any]] else { throw OverleafError.notLoggedIn }
        return list.compactMap(Self.project)
    }
    static func project(_ item: [String: Any]) -> OverleafProject? {
        guard let id = item["_id"] as? String ?? item["id"] as? String, let name = item["name"] as? String else { return nil }
        let updated = (item["lastUpdated"] as? String).flatMap { text -> Date? in
            let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        return OverleafProject(id: id, name: name, accessLevel: item["accessLevel"] as? String ?? "", lastUpdated: updated)
    }

    /// Downloads the whole project as a zip archive; the caller removes the file.
    public func downloadZip(projectID: String) async throws -> URL {
        let (file, response) = try await session.download(for: URLRequest(url: url("project/\(projectID)/download/zip")))
        _ = try check(response, nil)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX-overleaf-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: file, to: target); return target
    }

    private func multipart(_ path: String, query: [String: String], fields: [(String, String)], fileName: String, file: Data) async throws -> [String: Any] {
        let boundary = "BetterTeX-\(UUID().uuidString)"
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for (name, value) in fields { line("--\(boundary)"); line("Content-Disposition: form-data; name=\"\(name)\""); line(""); line(value) }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "_")
        line("--\(boundary)"); line("Content-Disposition: form-data; name=\"qqfile\"; filename=\"\(safeName)\""); line("Content-Type: application/octet-stream"); line("")
        body.append(file); line(""); line("--\(boundary)--")
        func attempt() async throws -> [String: Any] {
            var request = URLRequest(url: url(path, query: query)); request.httpMethod = "POST"; request.timeoutInterval = 180
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue(try await token(), forHTTPHeaderField: "X-Csrf-Token")
            let (data, response) = try await session.upload(for: request, from: body)
            _ = try check(response, data); return object(data)
        }
        do { return try await attempt() }
        catch OverleafError.http(403, _) { csrf = nil; return try await attempt() }
    }

    /// Creates or replaces one file. Missing folders along `path` are created by Overleaf.
    public func upload(projectID: String, rootFolderID: String, path: String, data: Data) async throws {
        let name = (path as NSString).lastPathComponent
        var fields = [("name", name)]
        if path.contains("/") { fields.append(("relativePath", path)) }
        let result = try await multipart("project/\(projectID)/upload", query: ["folder_id": rootFolderID], fields: fields, fileName: name, file: data)
        guard result["success"] as? Bool == true else { throw OverleafError.message("Overleaf 拒绝了 \(path)：\(result["error"] as? String ?? "上传失败")") }
    }

    /// Uploads a zip archive as a brand-new project and returns its id.
    public func createProject(name: String, archive: URL) async throws -> String {
        let result = try await multipart("project/new/upload", query: [:], fields: [("name", name + ".zip")], fileName: name + ".zip", file: try Data(contentsOf: archive))
        guard let id = result["project_id"] as? String else { throw OverleafError.message("Overleaf 未能创建项目：\(result["error"] as? String ?? "未知错误")") }
        return id
    }

    public func delete(projectID: String, entity: OverleafEntity) async throws {
        try await send("DELETE", "project/\(projectID)/\(entity.kind.rawValue)/\(entity.id)")
    }

    // MARK: Collaborators
    /// Sends an invitation e-mail. `privileges` is `readAndWrite`, `readOnly` or `review`.
    public func invite(projectID: String, email: String, privileges: String) async throws {
        let result = object(try await send("POST", "project/\(projectID)/invite", json: ["email": email, "privileges": privileges]))
        if result["invite"] is [String: Any] { return }
        switch result["error"] as? String {
        case "cannot_invite_self": throw OverleafError.message("不能邀请自己。")
        case "cannot_invite_non_user": throw OverleafError.message("该邮箱尚未注册 Overleaf。")
        case let code?: throw OverleafError.message("邀请失败：\(code)")
        default: throw OverleafError.message("邀请没有发出，可能已超出该项目的协作者上限。")
        }
    }
    /// Members and pending invitations as (display name, role) pairs.
    public func members(projectID: String) async throws -> [(name: String, role: String)] {
        var result: [(String, String)] = []
        for member in object(try await send("GET", "project/\(projectID)/members"))["members"] as? [[String: Any]] ?? [] {
            let name = [member["first_name"] as? String, member["last_name"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let email = member["email"] as? String ?? ""
            result.append((name.isEmpty ? email : "\(name) · \(email)", member["privileges"] as? String ?? ""))
        }
        for invite in (object((try? await send("GET", "project/\(projectID)/invites")) ?? Data())["invites"] as? [[String: Any]]) ?? [] {
            result.append((invite["email"] as? String ?? "", "pending:" + (invite["privileges"] as? String ?? "")))
        }
        return result
    }

    // MARK: Comments
    public func threads(projectID: String) async throws -> [String: OverleafThread] {
        var result: [String: OverleafThread] = [:]
        for (id, value) in object(try await send("GET", "project/\(projectID)/threads")) {
            guard let thread = value as? [String: Any] else { continue }
            let messages = (thread["messages"] as? [[String: Any]] ?? []).map { message -> OverleafMessage in
                let user = message["user"] as? [String: Any] ?? [:]
                let name = [user["first_name"] as? String, user["last_name"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                return OverleafMessage(id: message["id"] as? String ?? UUID().uuidString, content: message["content"] as? String ?? "",
                                       author: name.isEmpty ? (user["email"] as? String ?? "协作者") : name,
                                       date: Date(timeIntervalSince1970: (message["timestamp"] as? Double ?? 0) / 1000))
            }
            result[id] = OverleafThread(id: id, messages: messages, resolved: thread["resolved"] as? Bool ?? false)
        }
        return result
    }
    public func reply(projectID: String, thread: String, content: String) async throws {
        try await send("POST", "project/\(projectID)/thread/\(thread)/messages", json: ["content": content])
    }
    public func setResolved(_ resolved: Bool, projectID: String, docID: String, thread: String) async throws {
        try await send("POST", "project/\(projectID)/doc/\(docID)/thread/\(thread)/\(resolved ? "resolve" : "reopen")", json: [:])
    }
}

/// A minimal socket.io 0.9 client for Overleaf's real-time service. Callbacks arrive on the main queue.
public final class OverleafSocket: NSObject, URLSessionWebSocketDelegate {
    public var onEvent: ((String, [Any]) -> Void)?
    public var onClose: ((String) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var acks: [Int: ([Any]) -> Void] = [:]
    private var nextAck = 1
    private var closed = false
    public private(set) var isOpen = false

    public func connect(client: OverleafClient, projectID: String) async throws {
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        var handshake = URLRequest(url: client.url("socket.io/1/", query: ["projectId": projectID, "t": stamp]))
        handshake.setValue(client.host.absoluteString, forHTTPHeaderField: "Origin")
        let (data, response) = try await client.session.data(for: handshake)
        guard let http = response as? HTTPURLResponse else { throw OverleafError.message("无法连接 Overleaf 实时服务。") }
        if http.statusCode == 401 || http.statusCode == 403 { throw OverleafError.notLoggedIn }
        let fields = String(decoding: data, as: UTF8.self).split(separator: ":")
        guard http.statusCode == 200, let sid = fields.first, fields.count >= 3 else { throw OverleafError.http(http.statusCode, "实时服务握手失败") }
        var components = URLComponents(url: client.url("socket.io/1/websocket/\(sid)", query: ["projectId": projectID]), resolvingAgainstBaseURL: false)!
        components.scheme = client.host.scheme == "http" ? "ws" : "wss"
        var request = URLRequest(url: components.url!)
        request.setValue(client.host.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(client.cookieHeader, forHTTPHeaderField: "Cookie")
        let task = client.session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task; closed = false; task.resume(); receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.task === task, !self.closed else { return }
                switch result {
                case .failure(let error): self.finish(error.localizedDescription)
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(task)
                }
            }
        }
    }
    private func handle(_ text: String) {
        if ProcessInfo.processInfo.environment["BETTERTEX_OVERLEAF_TRACE"] == "1" { print("LIVE frame", text.prefix(300)) }
        guard let frame = SocketIOFrame.parse(text) else { return }
        switch frame {
        case .connect: isOpen = true
        case .heartbeat: task?.send(.string("2::")) { _ in }
        case .disconnect: finish("服务器断开了连接")
        case .error(let reason): finish(reason)
        case .event(let name, let args, _): onEvent?(name, args)
        case .ack(let id, let args): if let callback = acks.removeValue(forKey: id) { callback(args) }
        case .noop: break
        }
    }
    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true; isOpen = false; acks.removeAll(); task?.cancel(with: .goingAway, reason: nil); task = nil
        onClose?(reason)
    }

    /// Sends an event; `ack` receives the server's callback arguments (error first).
    public func emit(_ name: String, _ args: [Any] = [], ack: (([Any]) -> Void)? = nil) {
        guard let task, !closed else { return }
        var id: Int?
        if let ack { id = nextAck; nextAck += 1; acks[id!] = ack }
        task.send(.string(SocketIOFrame.encodeEvent(name, args: args, ackID: id))) { [weak self] error in
            if let error { DispatchQueue.main.async { self?.finish(error.localizedDescription) } }
        }
    }
    /// Closes quietly; `onClose` is not called.
    public func close() {
        guard !closed else { return }
        closed = true; isOpen = false; acks.removeAll()
        task?.send(.string("0::")) { _ in }; task?.cancel(with: .normalClosure, reason: nil); task = nil
    }
}
