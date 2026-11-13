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

/// What latexmk needs to resume from the last good build. A failed or stopped pass leaves a truncated
/// `.aux` behind (`-halt-on-error` stops TeX midway), and the next build would then redo the bibliography
/// and every pass. Keeping the good state aside and putting it back after a failure keeps the next
/// build to the passes the edit itself needs — usually one.
public struct BuildState {
    static let suffixes = [".aux", ".bbl", ".bcf", ".run.xml", ".out", ".toc", ".lof", ".lot", ".loa", ".fls", ".fdb_latexmk",
                           ".nav", ".snm", ".vrb", ".idx", ".ind", ".ilg", ".glo", ".gls", ".glg", ".ist", ".brf", ".thm",
                           ".synctex.gz", ".synctex", ".xdv", ".dvi", ".pdf"]
    /// Folders inside the output directory that are not TeX's.
    static let foreign: Set<String> = ["preview", "overleaf-base", "last-good"]
    let output: URL
    var saved: URL { output.appendingPathComponent("last-good", isDirectory: true) }
    public init(output: URL) { self.output = output }

    /// Output-relative paths of the build files under `directory`.
    func files(in directory: URL) -> [String] {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var paths: [String] = []
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if directory == output, Self.foreign.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            let name = url.lastPathComponent.lowercased()
            guard Self.suffixes.contains(where: name.hasSuffix) else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix(base) { paths.append(String(path.dropFirst(base.count))) }
        }
        return paths
    }
    /// Replaces the kept state with the files of a build that just succeeded.
    public func keep() {
        let manager = FileManager.default
        try? manager.removeItem(at: saved)
        for path in files(in: output) { Self.copy(output.appendingPathComponent(path), to: saved.appendingPathComponent(path)) }
    }
    /// Puts the last good state back after a build that failed or was stopped.
    public func restore() {
        for path in files(in: saved) { Self.copy(saved.appendingPathComponent(path), to: output.appendingPathComponent(path)) }
    }
    /// Copies are clones on APFS, so even a large PDF costs next to nothing.
    static func copy(_ source: URL, to target: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: target)
        try? manager.copyItem(at: source, to: target)
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
        let state = BuildState(output: output)
        var kept = false
        // Whatever ends this build early (an error, Stop, a missing tool) must not cost the next one its passes.
        defer { if !kept { state.restore() } }
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
                if FileManager.default.fileExists(atPath: source.path) { BuildState.copy(source, to: target) }
                else if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            }
            state.keep(); kept = true
        }
        return BuildResult(root: root, pdf: previewPDF, engine: engine, succeeded: succeeded, log: log, seconds: Date().timeIntervalSince(started))
    }
}
