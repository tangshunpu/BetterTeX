import Foundation

public struct BuildResult {
    public let root: URL
    public let pdf: URL
    public let engine: TeXEngine
    public let succeeded: Bool
    public let log: String
    public let seconds: TimeInterval
    public var diagnostics: [TeXDiagnostic] { TeXDiagnostic.parse(log) }
}

/// One program run inside a build (a typesetting pass, the bibliography tool, …).
public struct BuildStage: Equatable {
    public let tool: String
    /// How many times this tool has run in the current build, starting at 1.
    public let pass: Int
    /// Position of this run in the whole build, starting at 1.
    public let step: Int
    public var title: String {
        switch tool {
        case "pdflatex", "xelatex", "lualatex", "latex", "xdvipdfmx", "dvipdfmx": return L10n.tr("排版 · 第 \(pass) 遍")
        case "bibtex", "bibtex8", "bibtexu", "biber": return L10n.tr("整理参考文献")
        case "makeindex", "xindy", "texindy", "makeglossaries", "bib2gls": return L10n.tr("生成索引")
        default: return tool
        }
    }
}

/// Follows a build's console output and reports each program latexmk starts.
public struct BuildStageTracker {
    private var partial = ""
    private var counts: [String: Int] = [:]
    private var step = 0
    public init() {}
    public mutating func begin(_ tool: String) -> BuildStage {
        let name = (tool as NSString).lastPathComponent.lowercased()
        counts[name, default: 0] += 1; step += 1
        return BuildStage(tool: name, pass: counts[name]!, step: step)
    }
    /// Feeds a chunk of output; returns the stages that started within it.
    public mutating func consume(_ text: String) -> [BuildStage] {
        partial += text
        var stages: [BuildStage] = []
        while let newline = partial.firstIndex(of: "\n") {
            let line = partial[..<newline]; partial = String(partial[partial.index(after: newline)...])
            // latexmk announces every program as: Running 'pdflatex  -interaction=…'
            guard line.hasPrefix("Running '") else { continue }
            let command = line.dropFirst("Running '".count)
            let tool = command.prefix { $0 != " " && $0 != "'" }
            if !tool.isEmpty { stages.append(begin(String(tool))) }
        }
        if partial.utf8.count > 8_000 { partial = String(partial.suffix(2_000)) }
        return stages
    }
}

public enum BuildSignature {
    /// A fingerprint of everything a build reads: source files (path, size, modification time),
    /// the root document and the engine. Equal fingerprints mean a rebuild would change nothing.
    public static func compute(project: URL, root: String, engine: String) -> String {
        var entries: [String] = ["root=\(root)", "engine=\(engine)"]
        let base = project.standardizedFileURL.path
        if let iterator = FileManager.default.enumerator(at: project, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            var visited = 0
            while let url = iterator.nextObject() as? URL {
                visited += 1; if visited > 20_000 { entries.append("truncated"); break }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), values.isRegularFile == true else { continue }
                let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                entries.append("\(url.standardizedFileURL.path.dropFirst(base.count))|\(values.fileSize ?? 0)|\(stamp)")
            }
        }
        return entries.sorted().joined(separator: "\n")
    }
}

public final class TeXCompiler {
    public let runner = ProcessRunner()
    public init() {}

    public func build(active: URL, project: URL, selected: TeXEngine, tools: Toolchain,
                      onStage: ((BuildStage) -> Void)? = nil, onOutput: ((String) -> Void)? = nil) throws -> BuildResult {
        var tracker = BuildStageTracker()
        let started = Date()
        let root = try TeXProject.root(active: active, project: project)
        let directory = root.deletingLastPathComponent()
        let output = directory.appendingPathComponent(".bettertex", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let engine = TeXProject.engine(for: try String(contentsOf: root, encoding: .utf8), selected: selected)
        guard let executable = tools[engine.executable] else { throw BetterTeXError.message(L10n.tr("未检测到 \(engine.rawValue)。请安装 MacTeX / BasicTeX，或选择已安装的引擎。")) }
        let basename = root.deletingPathExtension().lastPathComponent
        let pdf = output.appendingPathComponent(basename + ".pdf")
        var log = ""; var status: Int32 = 0
        func execute(_ path: String, _ arguments: [String], cwd: URL = directory, env: [String: String]? = nil) throws {
            let header = "\n› \(URL(fileURLWithPath: path).lastPathComponent) \(arguments.joined(separator: " "))\n"
            log += header; onOutput?(header)
            // latexmk drives several programs itself and names them in its output; other tools are one stage each.
            let supervised = URL(fileURLWithPath: path).lastPathComponent == "latexmk"
            if !supervised { onStage?(tracker.begin(path)) }
            let result = try runner.run(path, arguments, directory: cwd, environment: env ?? tools.environment, timeout: 180) { text in
                if supervised { for stage in tracker.consume(text) { onStage?(stage) } }
                onOutput?(text)
            }
            log += result.output; status = result.status
            if log.utf8.count > 700_000 { log = String(log.suffix(500_000)) }
        }
        if let latexmk = tools["latexmk"] {
            let flag = engine == .xeLaTeX ? "-xelatex" : engine == .luaLaTeX ? "-lualatex" : "-pdf"
            try execute(latexmk, [flag, "-interaction=nonstopmode", "-halt-on-error", "-file-line-error", "-synctex=1", "-outdir=\(output.path)", root.path])
        } else {
            if selected == .latexmk { throw BetterTeXError.message(L10n.tr("未检测到 latexmk，请选择 Auto 或已安装的 TeX 引擎。")) }
            let args = ["-interaction=nonstopmode", "-halt-on-error", "-file-line-error", "-synctex=1", "-recorder", "-output-directory=\(output.path)", root.path]
            try execute(executable, args)
            if status == 0 {
                let aux = (try? String(contentsOf: output.appendingPathComponent(basename + ".aux"))) ?? ""
                let needsBiber = FileManager.default.fileExists(atPath: output.appendingPathComponent(basename + ".bcf").path)
                let needsBibtex = aux.contains("\\bibdata")
                if needsBiber || needsBibtex {
                    let name = needsBiber ? "biber" : "bibtex"
                    guard let bib = tools[name] else { throw BetterTeXError.message(L10n.tr("该文档需要 \(name)，但本机尚未安装。")) }
                    var env = tools.environment
                    env["BIBINPUTS"] = directory.path + ":" + (env["BIBINPUTS"] ?? "")
                    env["BSTINPUTS"] = directory.path + ":" + (env["BSTINPUTS"] ?? "")
                    try execute(bib, [basename], cwd: output, env: env)
                }
                if status == 0 { try execute(executable, args) }
                if status == 0 { try execute(executable, args) }
            }
        }
        let succeeded = status == 0 && FileManager.default.fileExists(atPath: pdf.path)
        let previewDirectory = output.appendingPathComponent("preview", isDirectory: true)
        let previewPDF = previewDirectory.appendingPathComponent(basename + ".pdf")
        if succeeded {
            try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
            for suffix in [".pdf", ".synctex.gz", ".synctex"] {
                let source = output.appendingPathComponent(basename + suffix)
                let target = previewDirectory.appendingPathComponent(basename + suffix)
                if FileManager.default.fileExists(atPath: source.path) { try Data(contentsOf: source).write(to: target, options: .atomic) }
                else if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            }
        }
        return BuildResult(root: root, pdf: previewPDF, engine: engine, succeeded: succeeded, log: log, seconds: Date().timeIntervalSince(started))
    }
}
