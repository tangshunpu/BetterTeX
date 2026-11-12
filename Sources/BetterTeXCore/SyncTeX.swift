import Foundation

public struct PDFLocation {
    public let page: Int
    public let x: Double
    public let y: Double
    public func point(mediaHeight: Double, originX: Double = 0, originY: Double = 0) -> CGPoint {
        CGPoint(x: originX + x, y: originY + mediaHeight - y)
    }
}
public struct SourceLocation { public let file: URL; public let line: Int; public let column: Int }
/// One box SyncTeX attributes to a source line, in PDF points from the page's top-left corner.
/// `h`/`v` are the box's left edge and baseline; it extends `height` above the baseline.
public struct SyncBox: Equatable {
    public let page: Int
    public let x: Double, y: Double
    public let h: Double, v: Double
    public let width: Double, height: Double
    public var location: PDFLocation { PDFLocation(page: page, x: x, y: y) }
}

public enum SyncTeX {
    public static func fields(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]); if result[key] == nil { result[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        }
        return result
    }
    public static func parseForward(_ output: String) -> PDFLocation? {
        let values = fields(output)
        guard let page = Int(values["Page"] ?? ""), page > 0,
              let x = Double(values["x"] ?? values["h"] ?? ""), let y = Double(values["y"] ?? values["v"] ?? "") else { return nil }
        return PDFLocation(page: page, x: x, y: y)
    }
    /// Every box in a `synctex view` result; one source line usually spans several.
    public static func parseBoxes(_ output: String) -> [SyncBox] {
        var boxes: [SyncBox] = []; var current: [String: String] = [:]
        func flush() {
            if let page = Int(current["Page"] ?? ""), page > 0, let x = Double(current["x"] ?? ""), let y = Double(current["y"] ?? "") {
                boxes.append(SyncBox(page: page, x: x, y: y, h: Double(current["h"] ?? "") ?? x, v: Double(current["v"] ?? "") ?? y,
                                     width: Double(current["W"] ?? "") ?? 0, height: Double(current["H"] ?? "") ?? 0))
            }
            current = [:]
        }
        for line in output.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]), value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "Output" || key == "Page" && current["Page"] != nil { flush() }
            current[key] = value
        }
        flush()
        return boxes
    }
    public static func boxes(file: URL, line: Int, pdf: URL, tools: Toolchain) -> [SyncBox] {
        guard let binary = tools["synctex"],
              let result = try? ProcessRunner().run(binary, ["view", "-i", "\(line):0:\(file.path)", "-o", pdf.path], environment: tools.environment, timeout: 10),
              result.succeeded else { return [] }
        return parseBoxes(result.output)
    }
    public static func parseInverse(_ output: String, directory: URL) -> SourceLocation? {
        let values = fields(output)
        guard let path = values["Input"], let line = Int(values["Line"] ?? ""), line > 0 else { return nil }
        let base = URL(fileURLWithPath: directory.path, isDirectory: true)
        return SourceLocation(file: URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL, line: line, column: max(0, Int(values["Column"] ?? "") ?? 0))
    }
    public static func forward(file: URL, line: Int, column: Int, pdf: URL, tools: Toolchain) throws -> PDFLocation {
        guard let binary = tools["synctex"] else { throw BetterTeXError.message(L10n.tr("未检测到 synctex。请在 TeX 发行版中安装 SyncTeX。")) }
        let result = try ProcessRunner().run(binary, ["view", "-i", "\(line):\(column):\(file.path)", "-o", pdf.path], environment: tools.environment, timeout: 10)
        guard result.succeeded, let point = parseForward(result.output) else { throw BetterTeXError.message(L10n.tr("该位置没有 PDF 映射。请先成功编译，并选择正文所在行。")) }
        return point
    }
    public static func inverse(page: Int, x: Double, y: Double, pdf: URL, root: URL, tools: Toolchain) throws -> SourceLocation {
        guard let binary = tools["synctex"] else { throw BetterTeXError.message(L10n.tr("未检测到 synctex。")) }
        let result = try ProcessRunner().run(binary, ["edit", "-o", "\(page):\(x):\(y):\(pdf.path)"], directory: root.deletingLastPathComponent(), environment: tools.environment, timeout: 10)
        guard result.succeeded, let location = parseInverse(result.output, directory: root.deletingLastPathComponent()) else { throw BetterTeXError.message(L10n.tr("此处没有对应的 TeX 源码。")) }
        return location
    }
}
