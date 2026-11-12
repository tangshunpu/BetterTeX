import Foundation

/// BibTeX / biblatex entry types offered after "@" in a .bib file, most common first.
public enum BibEntryType {
    public struct Info { public let name: String; let summaryText: LocalizedText; public let fields: [String]
        init(name: String, summary: LocalizedText, fields: [String]) { self.name = name; summaryText = summary; self.fields = fields }
        public var summary: String { L10n.tr(summaryText) } }
    public static let all: [Info] = [
        Info(name: "article", summary: "期刊论文", fields: ["author", "title", "journal", "year", "volume", "number", "pages", "doi"]),
        Info(name: "inproceedings", summary: "会议论文", fields: ["author", "title", "booktitle", "year", "pages", "doi"]),
        Info(name: "misc", summary: "其他（预印本、网页等）", fields: ["author", "title", "howpublished", "year", "note"]),
        Info(name: "book", summary: "书籍", fields: ["author", "title", "publisher", "year", "address"]),
        Info(name: "incollection", summary: "文集中的章节", fields: ["author", "title", "booktitle", "editor", "publisher", "year", "pages"]),
        Info(name: "inbook", summary: "书中的章节或页", fields: ["author", "title", "chapter", "publisher", "year", "pages"]),
        Info(name: "phdthesis", summary: "博士论文", fields: ["author", "title", "school", "year"]),
        Info(name: "mastersthesis", summary: "硕士论文", fields: ["author", "title", "school", "year"]),
        Info(name: "techreport", summary: "技术报告", fields: ["author", "title", "institution", "number", "year"]),
        Info(name: "online", summary: "网络资源（biblatex）", fields: ["author", "title", "url", "urldate", "year"]),
        Info(name: "proceedings", summary: "会议论文集", fields: ["title", "editor", "publisher", "year"]),
        Info(name: "conference", summary: "会议论文（同 inproceedings）", fields: ["author", "title", "booktitle", "year", "pages"]),
        Info(name: "unpublished", summary: "未发表", fields: ["author", "title", "note", "year"]),
        Info(name: "manual", summary: "技术手册", fields: ["title", "author", "organization", "year"]),
        Info(name: "booklet", summary: "小册子", fields: ["title", "author", "howpublished", "year"]),
        Info(name: "string", summary: "字符串缩写", fields: []),
        Info(name: "preamble", summary: "导言", fields: []),
        Info(name: "comment", summary: "注释", fields: [])
    ]
    /// Entries that are not references and therefore have no citation key.
    static let special: Set<String> = ["string", "preamble", "comment"]

    /// Completion items: label "@article", inserting the whole entry skeleton with the caret on the key.
    public static func items(newline: String = "\n") -> [CompletionItem] {
        all.map { info in
            let detail = info.summary + (info.fields.isEmpty ? "" : " · " + info.fields.prefix(4).joined(separator: ", "))
            if special.contains(info.name) {
                let insert = "@\(info.name){}"
                return CompletionItem(label: "@" + info.name, detail: detail, insert: insert, caret: (insert as NSString).length - 1)
            }
            let head = "@\(info.name){"
            let body = info.fields.map { "  \($0) = {}," }.joined(separator: newline)
            let insert = head + "," + newline + body + newline + "}"
            return CompletionItem(label: "@" + info.name, detail: detail, insert: insert, caret: (head as NSString).length)
        }
    }

    /// The colour family used to tell entry types apart at a glance.
    public enum Family { case journal, conference, book, thesis, report, web, other, special }
    public static func family(of type: String) -> Family {
        switch type.lowercased() {
        case "article", "periodical": return .journal
        case "inproceedings", "conference", "proceedings": return .conference
        case "book", "inbook", "incollection", "booklet", "collection", "mvbook": return .book
        case "phdthesis", "mastersthesis", "thesis": return .thesis
        case "techreport", "report", "manual": return .report
        case "online", "www", "electronic", "misc": return .web
        case "string", "preamble", "comment": return .special
        default: return .other
        }
    }
}

extension CompletionRequest {
    private static let bibEntryStart = try! NSRegularExpression(pattern: "^[ \\t]*@([a-zA-Z]*)$")
    /// Completion in a .bib file: only an entry type being typed after "@" at the start of a line.
    public static func detect(inBib text: String, cursor: Int) -> CompletionRequest? {
        let ns = text as NSString
        guard cursor >= 0, cursor <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        guard let match = bibEntryStart.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else { return nil }
        let at = match.range(at: 1).location - 1
        return CompletionRequest(kind: .bibEntry, command: "@", prefix: (before as NSString).substring(with: match.range(at: 1)),
                                 range: NSRange(location: lineStart + at, length: cursor - lineStart - at))
    }
}
