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

public final class TeXCompiler {
    public let runner = ProcessRunner()
    public init() {}

    public func build(active: URL, project: URL, selected: TeXEngine, tools: Toolchain,
                      onOutput: ((String) -> Void)? = nil) throws -> BuildResult {
        let started = Date()
        let root = try TeXProject.root(active: active, project: project)
        let directory = root.deletingLastPathComponent()
        let output = directory.appendingPathComponent(".bettertex", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let engine = TeXProject.engine(for: try String(contentsOf: root, encoding: .utf8), selected: selected)
        guard let executable = tools[engine.executable] else { throw BetterTeXError.message("未检测到 \(engine.rawValue)。请安装 MacTeX / BasicTeX，或选择已安装的引擎。") }
        let basename = root.deletingPathExtension().lastPathComponent
        let pdf = output.appendingPathComponent(basename + ".pdf")
        var log = ""; var status: Int32 = 0
        func execute(_ path: String, _ arguments: [String], cwd: URL = directory, env: [String: String]? = nil) throws {
            let header = "\n› \(URL(fileURLWithPath: path).lastPathComponent) \(arguments.joined(separator: " "))\n"
            log += header; onOutput?(header)
            let result = try runner.run(path, arguments, directory: cwd, environment: env ?? tools.environment, timeout: 180, onOutput: onOutput)
            log += result.output; status = result.status
            if log.utf8.count > 700_000 { log = String(log.suffix(500_000)) }
        }
        if let latexmk = tools["latexmk"] {
            let flag = engine == .xeLaTeX ? "-xelatex" : engine == .luaLaTeX ? "-lualatex" : "-pdf"
            try execute(latexmk, [flag, "-interaction=nonstopmode", "-halt-on-error", "-file-line-error", "-synctex=1", "-outdir=\(output.path)", root.path])
        } else {
            if selected == .latexmk { throw BetterTeXError.message("未检测到 latexmk，请选择 Auto 或已安装的 TeX 引擎。") }
            let args = ["-interaction=nonstopmode", "-halt-on-error", "-file-line-error", "-synctex=1", "-recorder", "-output-directory=\(output.path)", root.path]
            try execute(executable, args)
            if status == 0 {
                let aux = (try? String(contentsOf: output.appendingPathComponent(basename + ".aux"))) ?? ""
                let needsBiber = FileManager.default.fileExists(atPath: output.appendingPathComponent(basename + ".bcf").path)
                let needsBibtex = aux.contains("\\bibdata")
                if needsBiber || needsBibtex {
                    let name = needsBiber ? "biber" : "bibtex"
                    guard let bib = tools[name] else { throw BetterTeXError.message("该文档需要 \(name)，但本机尚未安装。") }
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
