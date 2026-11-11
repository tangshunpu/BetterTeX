import Foundation

public struct PreparedAppUpdate: Sendable {
    public let directory: URL
    public let application: URL
    public let destination: URL
    public func discard() { try? FileManager.default.removeItem(at: directory) }
}

/// Staging and validation happen before quitting. Only the small installer runs after exit.
public enum UpdateInstaller {
    public static let resultURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BetterTeX/Updates/install-result")
    static var scriptURL: URL { Bundle.module.url(forResource: "install-update", withExtension: "sh")! }

    public static func checkDestination(_ destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        guard destination.pathExtension == "app", !destination.pathComponents.contains("AppTranslocation"),
              !destination.path.hasPrefix("/Volumes/"),
              destination.standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL,
              FileManager.default.isWritableFile(atPath: destination.path), FileManager.default.isWritableFile(atPath: parent.path) else {
            throw BetterTeXError.message(L10n.tr("请先将 BetterTeX 移到可写的「应用程序」文件夹，再安装更新。"))
        }
    }

    public static func prepare(archive: URL, release: AppRelease, destination: URL) throws -> PreparedAppUpdate {
        try checkDestination(destination)
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".BetterTeX-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let listing = try command("/usr/bin/unzip", ["-Z1", archive.path])
            let entries = listing.split(separator: "\n").map(String.init)
            guard !entries.isEmpty, entries.allSatisfy({ path in
                path.hasPrefix("BetterTeX.app/") && !path.components(separatedBy: "/").contains("..") && !path.contains("\\")
            }) else { throw invalidPackage() }
            // The current SwiftPM bundle has no symlinks. Reject archives capable of escaping the staging directory.
            let details = try command("/usr/bin/zipinfo", ["-l", archive.path])
            guard !details.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw invalidPackage() }
            try command("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
            let application = directory.appendingPathComponent("BetterTeX.app")
            try validateBundle(application, release: release, installed: destination)
            return PreparedAppUpdate(directory: directory, application: application, destination: destination)
        } catch { try? fm.removeItem(at: directory); throw error }
    }

    static func validateBundle(_ application: URL, release: AppRelease, installed: URL) throws {
        let infoURL = application.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
        guard let info, info["CFBundleIdentifier"] as? String == "dev.bettertex.app",
              info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleExecutable"] as? String == "BetterTeX",
              let version = info["BetterTeXReleaseVersion"] as? String,
              let expected = release.version, ReleaseVersion(version) == expected else { throw invalidPackage() }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let components = minimum.split(separator: ".", omittingEmptySubsequences: false)
            let parts = components.compactMap { Int($0) }
            guard parts.count == components.count, !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 >= 0 }) else { throw invalidPackage() }
            let required = OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(required) else {
                throw BetterTeXError.message(L10n.tr("此更新需要 macOS \(minimum) 或更新版本。"))
            }
        }
        let executable = application.appendingPathComponent("Contents/MacOS/BetterTeX")
        let architectures = try command("/usr/bin/lipo", ["-archs", executable.path]).split(whereSeparator: \.isWhitespace).map(String.init)
        guard architectures.contains(AppUpdateClient.architecture) else { throw BetterTeXError.message(L10n.tr("此更新不支持当前 Mac 的处理器架构。")) }
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", application.path])
        let oldTeam = try teamIdentifier(installed), newTeam = try teamIdentifier(application)
        if let oldTeam, oldTeam != newTeam { throw BetterTeXError.message(L10n.tr("更新应用的签名与当前版本不匹配。")) }
    }
    private static func teamIdentifier(_ app: URL) throws -> String? {
        let output = try command("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        let team = output.components(separatedBy: "\n").first { $0.hasPrefix("TeamIdentifier=") }?.dropFirst("TeamIdentifier=".count)
        guard let team, team != "not set", !team.isEmpty else { return nil }
        return String(team)
    }
    @discardableResult private static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let result = try ProcessRunner().run(executable, arguments)
        guard result.succeeded else { throw BetterTeXError.message(L10n.tr("无法验证或准备更新：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")) }
        return result.output
    }
    private static func invalidPackage() -> BetterTeXError { .message(L10n.tr("更新安装包无效，或版本与 Release 不一致。")) }

    /// The script is copied outside the old bundle before it is replaced. Every path is an argv value.
    @discardableResult public static func launch(_ update: PreparedAppUpdate, parentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                                                 result: URL = resultURL) throws -> Process {
        try checkDestination(update.destination)
        let script = update.directory.appendingPathComponent("install.sh")
        try Data(contentsOf: scriptURL).write(to: script, options: .atomic)
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = installerProcess(update, script: script, parentPID: parentPID, result: result)
        try process.run()
        return process
    }
    static func installerProcess(_ update: PreparedAppUpdate, script: URL = scriptURL, parentPID: Int32,
                                 result: URL, opener: String = "/usr/bin/open") -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(parentPID), update.destination.path, update.application.path,
                             update.directory.path, result.path, opener]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}
