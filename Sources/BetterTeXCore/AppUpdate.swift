import Foundation
import CryptoKit

/// SemVer precedence, including alpha.9 < alpha.10 < the final release.
public struct ReleaseVersion: Comparable, Equatable, Sendable {
    public let description: String
    public let numbers: [Int]
    public let prerelease: [String]

    public init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let ns = text as NSString
        let numbers = (1...3).compactMap { Int(ns.substring(with: match.range(at: $0))) }
        guard numbers.count == 3 else { return nil }
        let pre = match.range(at: 4).location == NSNotFound ? [] : ns.substring(with: match.range(at: 4)).components(separatedBy: ".")
        guard !pre.contains(where: { Self.numeric($0) && $0.count > 1 && $0.first == "0" }) else { return nil }
        description = text; self.numbers = numbers; prerelease = pre
    }
    private static func numeric(_ value: String) -> Bool { value.allSatisfy { $0.isASCII && $0.isNumber } }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let an = numeric(a), bn = numeric(b)
            if an && bn { return a.count == b.count ? a < b : a.count < b.count }
            if an != bn { return an }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
    public static func installed(in bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "BetterTeXReleaseVersion") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

public struct ReleaseAsset: Decodable, Sendable {
    public let name: String
    public let browserDownloadURL: URL
    public let size: Int64
    public let digest: String?
    enum CodingKeys: String, CodingKey { case name, size, digest; case browserDownloadURL = "browser_download_url" }
    public var sha256: String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hash = String(digest.dropFirst(7)).lowercased()
        return hash.count == 64 && hash.allSatisfy { $0.isASCII && $0.isHexDigit } ? hash : nil
    }
}

public struct AppRelease: Decodable, Sendable {
    public let tagName: String
    public let draft: Bool
    public let prerelease: Bool
    public let body: String?
    public let assets: [ReleaseAsset]
    enum CodingKeys: String, CodingKey { case draft, prerelease, body, assets; case tagName = "tag_name" }
    public var version: ReleaseVersion? { ReleaseVersion(tagName) }
    public var pageURL: URL { AppUpdateClient.releasesURL.appendingPathComponent("tag").appendingPathComponent(tagName) }
    public func asset(architecture: String = AppUpdateClient.architecture) -> ReleaseAsset? {
        // Prefer explicit architecture names. Never install a source-code archive.
        let version = version?.description ?? ""
        let names = ["BetterTeX-\(version)-macOS-\(architecture).zip", "BetterTeX-\(version)-macOS-universal.zip", "BetterTeX.zip"]
        return names.compactMap { name in
            assets.first { asset in
                asset.name == name && asset.size > 0 && asset.size <= 200 * 1024 * 1024 && asset.sha256 != nil
                    && asset.browserDownloadURL == AppUpdateClient.repositoryURL.appendingPathComponent("releases/download")
                        .appendingPathComponent(tagName).appendingPathComponent(name)
            }
        }.first
    }
    public static func newest(in releases: [Self], after current: ReleaseVersion, includePrereleases: Bool) -> Self? {
        releases.filter { release in
            guard !release.draft, let version = release.version, version > current else { return false }
            return includePrereleases || (!release.prerelease && version.prerelease.isEmpty)
        }.max { $0.version! < $1.version! }
    }
}

public struct UpdatePreferences {
    public static let automaticKey = "updates.automatic"
    public static let prereleasesKey = "updates.prereleases"
    public static let lastCheckKey = "updates.lastCheck"
    public static func automatic(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticKey) as? Bool ?? true
    }
    public static func includesPrereleases(current: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: prereleasesKey) as? Bool ?? !(ReleaseVersion(current)?.prerelease.isEmpty ?? true)
    }
    public static func isDue(now: Date = Date(), in defaults: UserDefaults = .standard) -> Bool {
        guard automatic(in: defaults) else { return false }
        guard let last = defaults.object(forKey: lastCheckKey) as? Date else { return true }
        return now.timeIntervalSince(last) >= 24 * 60 * 60 || last > now
    }
}

public struct AppUpdateClient {
    public static let repositoryURL = URL(string: "https://github.com/tangshunpu/BetterTeX")!
    public static let releasesURL = repositoryURL.appendingPathComponent("releases")
    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 600
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }
    public func check(current: String, includePrereleases: Bool) async throws -> AppRelease? {
        guard let version = ReleaseVersion(current) else { throw BetterTeXError.message(L10n.tr("无法识别当前应用的版本号。")) }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/tangshunpu/BetterTeX/releases?per_page=100")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("BetterTeX/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let releases = try JSONDecoder().decode([AppRelease].self, from: data)
        return AppRelease.newest(in: releases, after: version, includePrereleases: includePrereleases)
    }
    public func download(_ asset: ReleaseAsset, to destination: URL) async throws {
        let (temporary, response) = try await session.download(from: asset.browserDownloadURL)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.validate(response)
        guard response.url?.scheme == "https", let host = response.url?.host,
              ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host) else {
            throw BetterTeXError.message(L10n.tr("更新下载地址无效。"))
        }
        try Task.checkCancellation()
        try Self.verifyArchive(temporary, asset: asset)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw BetterTeXError.message(L10n.tr("更新服务器返回了无效响应。")) }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 || http.statusCode == 429 { throw BetterTeXError.message(L10n.tr("GitHub 暂时限制了更新请求，请稍后重试。")) }
            throw BetterTeXError.message(L10n.tr("检查或下载更新失败（HTTP \(http.statusCode)）。"))
        }
    }
    public static func verifyArchive(_ url: URL, asset: ReleaseAsset) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256(), count: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { count += Int64(data.count); hasher.update(data: data) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == asset.size, actual == asset.sha256 else { throw BetterTeXError.message(L10n.tr("更新文件校验失败，请重新下载。")) }
    }
}
