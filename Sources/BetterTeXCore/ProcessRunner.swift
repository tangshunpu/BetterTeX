import Foundation
import Darwin

public struct CommandResult {
    public let status: Int32
    public let output: String
    public var succeeded: Bool { status == 0 }
}

/// Runs argv directly (never via a shell), drains output continuously and bounds retained logs.
public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if let running, running.isRunning {
            running.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if running.isRunning { kill(running.processIdentifier, SIGKILL) } }
        }
    }

    public func reset() { lock.lock(); cancelled = false; lock.unlock() }

    public func run(_ executable: String, _ arguments: [String] = [], directory: URL? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval = 120,
                    onOutput: ((String) -> Void)? = nil) throws -> CommandResult {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.currentDirectoryURL = directory
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        lock.lock()
        if cancelled { lock.unlock(); throw BetterTeXError.message(L10n.tr("操作已取消。")) }
        process = child
        // Hold the lock through launch so cancel cannot miss a not-yet-running process.
        do { try child.run(); lock.unlock() }
        catch { process = nil; lock.unlock(); throw error }
        let deadline = DispatchWorkItem {
            if child.isRunning { child.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        var captured = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            captured.append(chunk)
            if captured.count > 512_000 { captured.removeFirst(captured.count - 512_000) }
            onOutput?(String(decoding: chunk, as: UTF8.self))
        }
        child.waitUntilExit()
        deadline.cancel()
        lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw BetterTeXError.message(L10n.tr("操作已取消。")) }
        return CommandResult(status: child.terminationStatus, output: String(decoding: captured, as: UTF8.self))
    }
}

public enum BetterTeXError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct Toolchain {
    public let environment: [String: String]
    public let paths: [String: String]
    public subscript(_ name: String) -> String? { paths[name] }

    public init(environment: [String: String], paths: [String: String]) {
        self.environment = environment; self.paths = paths
    }

    public static func discover() -> Toolchain {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shell = env["SHELL"] ?? "/bin/zsh"
        let loginPath = try? ProcessRunner().run(shell, ["-ilc", "printf '\\nBETTERTEX_PATH=%s\\n' \"$PATH\""], timeout: 6)
        let resolved = loginPath?.output.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("BETTERTEX_PATH=") })?.dropFirst("BETTERTEX_PATH=".count)
        let candidates = [String(resolved ?? ""), env["PATH"] ?? "", "/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "\(home)/.local/bin:\(home)/.cargo/bin:\(home)/.npm-global/bin"]
        var directories = candidates.joined(separator: ":").split(separator: ":").map(String.init)
        for base in ["\(home)/Library/TinyTeX/bin", "\(home)/.TinyTeX/bin"] {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: base) {
                directories.append(contentsOf: items.map { base + "/" + $0 })
            }
        }
        var seen = Set<String>(); directories = directories.filter { seen.insert($0).inserted }
        env["PATH"] = directories.joined(separator: ":")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        var tools: [String: String] = [:]
        for name in ["latexmk", "pdflatex", "xelatex", "lualatex", "bibtex", "biber", "synctex", "git", "codex", "claude"] {
            tools[name] = directories.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        return Toolchain(environment: env, paths: tools)
    }
}
