import Foundation

// Wire-level pieces of Overleaf's real-time service (socket.io 0.9 framing, the project
// tree and sharejs text operations). Everything here is pure and unit-tested.

/// One socket.io 0.9 frame: `type:id:endpoint:data`.
public enum SocketIOFrame {
    case disconnect, connect, heartbeat, noop
    case event(name: String, args: [Any], ackID: Int?)
    case ack(id: Int, args: [Any])
    case error(String)

    public static func parse(_ raw: String) -> SocketIOFrame? {
        let parts = raw.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard let type = parts.first else { return nil }
        let data = parts.count > 3 ? parts[3] : ""
        switch type {
        case "0": return .disconnect
        case "1": return .connect
        case "2": return .heartbeat
        case "8": return .noop
        case "7": return .error(data)
        case "5":
            guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any], let name = object["name"] as? String else { return nil }
            let id = parts.count > 1 ? Int(parts[1].replacingOccurrences(of: "+", with: "")) : nil
            return .event(name: name, args: object["args"] as? [Any] ?? [], ackID: id)
        case "6":
            // `id` or `id+[args]`
            let pieces = data.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let id = Int(pieces[0]) else { return nil }
            let args = pieces.count > 1 ? (try? JSONSerialization.jsonObject(with: Data(pieces[1].utf8)) as? [Any]) ?? [] : []
            return .ack(id: id, args: args)
        default: return nil
        }
    }

    /// Encodes an event; `ackID` asks the server to answer with an ack frame carrying data.
    public static func encodeEvent(_ name: String, args: [Any], ackID: Int?) -> String {
        let body = (try? JSONSerialization.data(withJSONObject: ["name": name, "args": args])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "5:\(ackID.map { "\($0)+" } ?? "")::\(body)"
    }
}

public struct OverleafEntity: Equatable {
    public enum Kind: String { case doc, file, folder }
    public let id: String
    public var name: String
    public let kind: Kind
    public var parent: String?
}

/// The project's file tree as sent in `joinProjectResponse`, kept current from tree events.
public struct OverleafTree {
    public private(set) var rootID: String
    public private(set) var entities: [String: OverleafEntity] = [:]

    public init?(project: [String: Any]) {
        guard let root = (project["rootFolder"] as? [[String: Any]])?.first, let id = root["_id"] as? String else { return nil }
        rootID = id
        entities[id] = OverleafEntity(id: id, name: "", kind: .folder, parent: nil)
        addFolderContents(root, id: id)
    }
    private mutating func addFolderContents(_ folder: [String: Any], id: String) {
        for doc in folder["docs"] as? [[String: Any]] ?? [] { add(doc, kind: .doc, parent: id) }
        for file in folder["fileRefs"] as? [[String: Any]] ?? [] { add(file, kind: .file, parent: id) }
        for sub in folder["folders"] as? [[String: Any]] ?? [] { add(sub, kind: .folder, parent: id) }
    }
    /// Adds an entity from its JSON description (folders bring their contents along).
    public mutating func add(_ json: [String: Any], kind: OverleafEntity.Kind, parent: String) {
        guard let id = json["_id"] as? String, let name = json["name"] as? String else { return }
        entities[id] = OverleafEntity(id: id, name: name, kind: kind, parent: parent)
        if kind == .folder { addFolderContents(json, id: id) }
    }
    public mutating func rename(_ id: String, to name: String) { entities[id]?.name = name }
    public mutating func move(_ id: String, to folder: String) { if id != rootID { entities[id]?.parent = folder } }
    public mutating func remove(_ id: String) {
        guard id != rootID else { return }
        for child in entities.values where child.parent == id { remove(child.id) }
        entities[id] = nil
    }
    /// The project-relative path of an entity, or nil when it is detached from the root.
    public func path(of id: String) -> String? {
        var names: [String] = []; var current = id; var hops = 0
        while current != rootID {
            guard let entity = entities[current], let parent = entity.parent, hops < 64 else { return nil }
            names.append(entity.name); current = parent; hops += 1
        }
        return names.reversed().joined(separator: "/")
    }
    public func entity(atPath path: String) -> OverleafEntity? {
        entities.values.first { $0.kind != .folder && self.path(of: $0.id) == path }
    }
}

/// One component of a sharejs text operation. Positions are UTF-16 offsets, as in JavaScript.
public struct TextOp: Equatable {
    public enum Kind { case insert, delete, comment }
    public let kind: Kind
    public let position: Int
    public let text: String
    public let thread: String?
    public init(_ kind: Kind, at position: Int, _ text: String, thread: String? = nil) {
        self.kind = kind; self.position = position; self.text = text; self.thread = thread
    }
    public var length: Int { (text as NSString).length }

    public init?(json: [String: Any]) {
        guard let position = json["p"] as? Int else { return nil }
        if let text = json["i"] as? String { self.init(.insert, at: position, text) }
        else if let text = json["d"] as? String { self.init(.delete, at: position, text) }
        else if let text = json["c"] as? String { self.init(.comment, at: position, text, thread: json["t"] as? String) }
        else { return nil }
    }
    public var json: [String: Any] {
        switch kind {
        case .insert: return ["p": position, "i": text]
        case .delete: return ["p": position, "d": text]
        case .comment: return ["p": position, "c": text, "t": thread ?? ""]
        }
    }
}

public struct CommentRange: Equatable {
    public let thread: String
    public var position: Int
    public var length: Int
    public var text: String
    public init(thread: String, position: Int, text: String) {
        self.thread = thread; self.position = position; self.text = text; length = (text as NSString).length
    }
    public init?(json: [String: Any]) {
        guard let op = json["op"] as? [String: Any], let position = op["p"] as? Int, let text = op["c"] as? String,
              let thread = op["t"] as? String ?? json["id"] as? String else { return nil }
        self.init(thread: thread, position: position, text: OverleafText.decode(text))
    }
}

public enum OverleafText {
    /// Document lines arrive as UTF-8 bytes packed into UTF-16 units (`unescape(encodeURIComponent(s))`).
    public static func decode(_ text: String) -> String {
        var bytes: [UInt8] = []; bytes.reserveCapacity(text.utf16.count)
        for unit in text.utf16 { guard unit < 256 else { return text }; bytes.append(UInt8(unit)) }
        return String(bytes: bytes, encoding: .utf8) ?? text
    }

    /// Applies operation components in order. A delete whose text does not match is rejected,
    /// which is how a diverged shadow copy is detected.
    public static func apply(_ ops: [TextOp], to text: String) throws -> String {
        let result = NSMutableString(string: text)
        for op in ops {
            switch op.kind {
            case .insert:
                guard op.position <= result.length else { throw BetterTeXError.message("Overleaf 更新与本地副本不一致。") }
                result.insert(op.text, at: op.position)
            case .delete:
                let range = NSRange(location: op.position, length: op.length)
                guard NSMaxRange(range) <= result.length, result.substring(with: range) == op.text else { throw BetterTeXError.message("Overleaf 更新与本地副本不一致。") }
                result.deleteCharacters(in: range)
            case .comment: break
            }
        }
        return result as String
    }

    /// The single splice (delete then insert) that turns `old` into `new`.
    public static func splice(from old: String, to new: String) -> [TextOp] {
        let a = old as NSString, b = new as NSString
        guard !a.isEqual(to: new) else { return [] }
        let limit = min(a.length, b.length)
        var prefix = 0
        while prefix < limit, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        // Never split a surrogate pair.
        if prefix > 0, UTF16.isLeadSurrogate(a.character(at: prefix - 1)) { prefix -= 1 }
        var suffix = 0
        while suffix < limit - prefix, a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a.character(at: a.length - suffix)) { suffix -= 1 }
        var ops: [TextOp] = []
        let removed = a.substring(with: NSRange(location: prefix, length: a.length - prefix - suffix))
        let inserted = b.substring(with: NSRange(location: prefix, length: b.length - prefix - suffix))
        if !removed.isEmpty { ops.append(TextOp(.delete, at: prefix, removed)) }
        if !inserted.isEmpty { ops.append(TextOp(.insert, at: prefix, inserted)) }
        return ops
    }

    /// Where an offset lands after `ops` have been applied.
    public static func shift(_ offset: Int, by ops: [TextOp]) -> Int {
        var offset = offset
        for op in ops {
            switch op.kind {
            case .insert: if op.position <= offset { offset += op.length }
            case .delete: if op.position < offset { offset -= min(op.length, offset - op.position) }
            case .comment: break
            }
        }
        return offset
    }

    /// Moves comment anchors along with edits; `comment` components add new anchors.
    public static func shift(_ comments: [CommentRange], by ops: [TextOp]) -> [CommentRange] {
        var comments = comments
        for op in ops {
            switch op.kind {
            case .comment:
                if let thread = op.thread, !comments.contains(where: { $0.thread == thread }) { comments.append(CommentRange(thread: thread, position: op.position, text: op.text)) }
            case .insert:
                for index in comments.indices {
                    if op.position <= comments[index].position { comments[index].position += op.length }
                    else if op.position < comments[index].position + comments[index].length { comments[index].length += op.length }
                }
            case .delete:
                let end = op.position + op.length
                for index in comments.indices {
                    let start = comments[index].position, stop = start + comments[index].length
                    let newStart = start <= op.position ? start : max(op.position, start - op.length)
                    let removedInside = max(0, min(stop, end) - max(start, op.position))
                    comments[index].position = newStart; comments[index].length = stop - start - removedInside
                }
            }
        }
        return comments
    }

    /// Converts Overleaf's zero-based (row, column) to a UTF-16 offset, clamped to the text.
    public static func offset(row: Int, column: Int, in text: String) -> Int {
        let ns = text as NSString; var location = 0, remaining = row
        while remaining > 0 {
            let newline = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location))
            if newline.location == NSNotFound { break }
            location = NSMaxRange(newline); remaining -= 1
        }
        let newline = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location))
        let lineEnd = newline.location == NSNotFound ? ns.length : newline.location
        return min(location + max(0, column), lineEnd)
    }
    public static func rowColumn(of offset: Int, in text: String) -> (row: Int, column: Int) {
        let ns = text as NSString; let offset = min(max(0, offset), ns.length)
        var row = 0, lineStart = 0, index = 0
        while index < offset { if ns.character(at: index) == 10 { row += 1; lineStart = index + 1 }; index += 1 }
        return (row, offset - lineStart)
    }

    /// A 24-hex id in the shape of a MongoDB ObjectId, used for new comment threads.
    public static func newObjectID() -> String {
        let seconds = String(format: "%08x", UInt32(Date().timeIntervalSince1970))
        return seconds + (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

public struct OverleafPresence: Equatable {
    public let clientID: String
    public var userID: String
    public var name: String
    public var email: String
    public var docID: String?
    public var row: Int
    public var column: Int

    /// Parses both `clientTracking.clientUpdated` payloads and `getConnectedUsers` entries.
    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String ?? json["client_id"] as? String else { return nil }
        clientID = id; userID = json["user_id"] as? String ?? ""
        email = json["email"] as? String ?? ""
        let full = json["name"] as? String ?? [json["first_name"] as? String, json["last_name"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        name = full.isEmpty ? (email.isEmpty ? "匿名用户" : email) : full
        let cursor = json["cursorData"] as? [String: Any] ?? json
        docID = cursor["doc_id"] as? String; row = cursor["row"] as? Int ?? 0; column = cursor["column"] as? Int ?? 0
    }
    public var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
    /// A stable hue in 0..<1 derived from the user id, so each collaborator keeps a colour.
    public var hue: Double {
        var hash: UInt32 = 2166136261
        for byte in (userID.isEmpty ? clientID : userID).utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return Double(hash % 360) / 360
    }
}
