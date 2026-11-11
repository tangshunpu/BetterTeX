import XCTest
import CryptoKit
@testable import BetterTeXCore

final class AppUpdateTests: XCTestCase {
    func testSemanticVersionPrecedenceAndMalformedVersions() throws {
        let versions = ["0.1.0-alpha.1", "0.1.0-alpha.2", "0.1.0-alpha.10", "0.1.0-beta", "0.1.0-rc.1", "0.1.0", "0.1.1", "0.10.0", "1.0.0"]
        let parsed = try versions.map { try XCTUnwrap(ReleaseVersion($0)) }
        XCTAssertEqual(parsed.reversed().sorted(), parsed)
        XCTAssertEqual(ReleaseVersion("v1.2.3+one"), ReleaseVersion("1.2.3+two"))
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("1.0.0-999999999999999999999")), try XCTUnwrap(ReleaseVersion("1.0.0-1000000000000000000000")))
        for invalid in ["", "latest", "1.2", "1.2.3.4", "01.2.3", "1.2.3-alpha.01", "1.2.3-", "1.2.3/foo"] { XCTAssertNil(ReleaseVersion(invalid), invalid) }
    }

    func testReleaseFilteringAndNoDowngrade() throws {
        let current = try XCTUnwrap(ReleaseVersion("0.1.0-alpha.2"))
        let releases = try [release("0.1.0-alpha.1", prerelease: true), release("0.1.0-alpha.10", prerelease: true), release("0.1.0"), release("0.2.0-beta.1", prerelease: true), release("9.0.0", draft: true), release("nightly")]
        XCTAssertEqual(AppRelease.newest(in: releases, after: current, includePrereleases: true)?.tagName, "v0.2.0-beta.1")
        XCTAssertEqual(AppRelease.newest(in: releases, after: current, includePrereleases: false)?.tagName, "v0.1.0")
        XCTAssertNil(AppRelease.newest(in: releases, after: ReleaseVersion("10.0.0")!, includePrereleases: true))
        XCTAssertNil(AppRelease.newest(in: [try release("0.2.0-alpha.1", prerelease: false)], after: current, includePrereleases: false))
    }

    func testOnlyTrustedCompatibleArchivesAreSelected() throws {
        let arm = assetObject("0.2.0", arch: "arm64"), intel = assetObject("0.2.0", arch: "x86_64")
        let universal = assetObject("0.2.0", arch: "universal")
        let value = try release("0.2.0", assets: [universal, intel, arm])
        XCTAssertEqual(value.asset(architecture: "arm64")?.name, arm["name"] as? String)
        XCTAssertEqual(value.asset(architecture: "x86_64")?.name, intel["name"] as? String)
        XCTAssertNil(try release("0.2.0", assets: [intel]).asset(architecture: "arm64"))
        for (key, replacement) in [("digest", "sha256:bad"), ("browser_download_url", "https://evil.example/update.zip"), ("size", 0 as Any), ("size", 300_000_000 as Any)] {
            var invalid = arm; invalid[key] = replacement
            XCTAssertNil(try release("0.2.0", assets: [invalid]).asset(architecture: "arm64"))
        }
    }

    func testCheckFrequencyAndPrereleaseDefaults() throws {
        let name = "BetterTeX.UpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        XCTAssertTrue(UpdatePreferences.isDue(now: now, in: defaults))
        XCTAssertTrue(UpdatePreferences.includesPrereleases(current: "0.1.0-alpha.2", in: defaults))
        XCTAssertFalse(UpdatePreferences.includesPrereleases(current: "1.0.0", in: defaults))
        defaults.set(now, forKey: UpdatePreferences.lastCheckKey)
        XCTAssertFalse(UpdatePreferences.isDue(now: now.addingTimeInterval(86_399), in: defaults))
        XCTAssertTrue(UpdatePreferences.isDue(now: now.addingTimeInterval(86_400), in: defaults))
        defaults.set(false, forKey: UpdatePreferences.automaticKey)
        XCTAssertFalse(UpdatePreferences.isDue(now: now.addingTimeInterval(172_800), in: defaults))
        defaults.set(false, forKey: UpdatePreferences.prereleasesKey)
        XCTAssertFalse(UpdatePreferences.includesPrereleases(current: "0.1.0-alpha.2", in: defaults))
    }

    func testReleaseRequestAndHTTPFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UpdateURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = AppUpdateClient(session: session)
        UpdateURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            return (200, Data(#"[{"tag_name":"v0.2.0","draft":false,"prerelease":false,"assets":[]}]"#.utf8))
        }
        let update = try await client.check(current: "0.1.0", includePrereleases: false)
        XCTAssertEqual(update?.tagName, "v0.2.0")
        for status in [403, 429, 500] {
            UpdateURLProtocol.handler = { _ in (status, Data()) }
            do { _ = try await client.check(current: "0.1.0", includePrereleases: true); XCTFail("HTTP \(status) must fail") } catch { }
        }
        UpdateURLProtocol.handler = { _ in (200, Data("invalid JSON".utf8)) }
        do { _ = try await client.check(current: "0.1.0", includePrereleases: true); XCTFail("Malformed response must fail") } catch { }
    }

    func testDigestAndSizeVerification() throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("update.zip"), data = Data("update bytes".utf8)
        try data.write(to: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var object = assetObject("0.2.0"); object["size"] = data.count; object["digest"] = "sha256:" + hash
        let asset = try decodeAsset(object)
        XCTAssertNoThrow(try AppUpdateClient.verifyArchive(url, asset: asset))
        try Data("tampered file".utf8).write(to: url)
        XCTAssertThrowsError(try AppUpdateClient.verifyArchive(url, asset: asset))
        object["digest"] = NSNull()
        XCTAssertThrowsError(try AppUpdateClient.verifyArchive(url, asset: decodeAsset(object)))
    }

    func testPrepareValidatesBundleAndLeavesInstalledAppUntouched() throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let installed = try makeApp(at: folder.appendingPathComponent("Installed/BetterTeX.app"), version: "0.1.0")
        let source = try makeApp(at: folder.appendingPathComponent("Source/BetterTeX.app"), version: "0.2.0")
        let archive = folder.appendingPathComponent("update.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, archive.path])
        let update = try UpdateInstaller.prepare(archive: archive, release: release("0.2.0"), destination: installed)
        defer { update.discard() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: update.application.path))
        XCTAssertEqual(try bundleVersion(installed), "0.1.0")
        XCTAssertEqual(try bundleVersion(update.application), "0.2.0")
        XCTAssertThrowsError(try UpdateInstaller.prepare(archive: archive, release: release("0.3.0"), destination: installed))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path).filter { $0.hasPrefix(".BetterTeX-update-") }.count, 1)
    }

    func testRejectsSymlinkArchiveAndInvalidDestination() throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let installed = try makeApp(at: folder.appendingPathComponent("Installed/BetterTeX.app"), version: "0.1.0")
        let source = try makeApp(at: folder.appendingPathComponent("Source/BetterTeX.app"), version: "0.2.0")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
        let archive = folder.appendingPathComponent("update.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, archive.path])
        XCTAssertThrowsError(try UpdateInstaller.prepare(archive: archive, release: release("0.2.0"), destination: installed))
        XCTAssertThrowsError(try UpdateInstaller.checkDestination(URL(fileURLWithPath: "/Volumes/BetterTeX/BetterTeX.app")))
        let alias = folder.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: installed)
        XCTAssertThrowsError(try UpdateInstaller.checkDestination(alias))
    }

    func testRejectsWrongIdentityUnsupportedOSAndDamagedSignature() throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let installed = try makeApp(at: folder.appendingPathComponent("Installed/BetterTeX.app"), version: "0.1.0")
        let source = try makeApp(at: folder.appendingPathComponent("Source/BetterTeX.app"), version: "0.2.0")
        let infoURL = source.appendingPathComponent("Contents/Info.plist")
        let original = try Data(contentsOf: infoURL)
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
        for (key, value) in [("CFBundleIdentifier", "another.app"), ("LSMinimumSystemVersion", "999.0"), ("LSMinimumSystemVersion", "13.bad"), ("BetterTeXReleaseVersion", "0.1.0")] {
            var modified = info; modified[key] = value
            try PropertyListSerialization.data(fromPropertyList: modified, format: .xml, options: 0).write(to: infoURL)
            XCTAssertThrowsError(try UpdateInstaller.validateBundle(source, release: release("0.2.0"), installed: installed), key)
        }
        try original.write(to: infoURL)
        let executable = source.appendingPathComponent("Contents/MacOS/BetterTeX")
        let handle = try FileHandle(forWritingTo: executable); try handle.seekToEnd(); try handle.write(contentsOf: Data("tampered".utf8)); try handle.close()
        XCTAssertThrowsError(try UpdateInstaller.validateBundle(source, release: release("0.2.0"), installed: installed))
    }

    func testInstallAndRollbackWithPathsContainingShellCharacters() throws {
        for shouldLaunch in [true, false] {
            let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
            let target = folder.appendingPathComponent("中文 ' $(touch WRONG) BetterTeX.app")
            let directory = folder.appendingPathComponent("stage ' with spaces")
            let next = directory.appendingPathComponent("BetterTeX.app")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: target.appendingPathComponent("marker"))
            try Data("new".utf8).write(to: next.appendingPathComponent("marker"))
            let update = PreparedAppUpdate(directory: directory, application: next, destination: target)
            let result = folder.appendingPathComponent("result")
            let process = UpdateInstaller.installerProcess(update, parentPID: Int32.max, result: result, opener: shouldLaunch ? "/usr/bin/true" : "/usr/bin/false")
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, shouldLaunch ? 0 : 1)
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("marker")), shouldLaunch ? "new" : "old")
            XCTAssertEqual(try String(contentsOf: result).trimmingCharacters(in: .whitespacesAndNewlines), shouldLaunch ? "installed" : "failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("WRONG").path))
        }
    }

    func testInstallerWaitsForOldProcessAndDoesNotReplaceWhileRunning() throws {
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("BetterTeX.app"), next = folder.appendingPathComponent("staged.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        let update = PreparedAppUpdate(directory: folder, application: next, destination: target)
        let process = UpdateInstaller.installerProcess(update, parentPID: ProcessInfo.processInfo.processIdentifier, result: folder.appendingPathComponent("result"), opener: "/usr/bin/true")
        try process.run()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.path))
        process.terminate(); process.waitUntilExit()
    }

    func testEnglishUpdateInterpolation() {
        let english = Localizer(language: .english)
        XCTAssertEqual(english.string("当前版本：\("0.2.0")"), "Current version: 0.2.0")
        XCTAssertEqual(english.string("检查或下载更新失败（HTTP \(429)）。"), "Could not check for or download updates (HTTP 429).")
    }

    private func release(_ version: String, prerelease: Bool = false, draft: Bool = false, assets: [[String: Any]] = []) throws -> AppRelease {
        try JSONDecoder().decode(AppRelease.self, from: JSONSerialization.data(withJSONObject: ["tag_name": "v" + version, "draft": draft, "prerelease": prerelease, "assets": assets]))
    }
    private func assetObject(_ version: String, arch: String = "arm64") -> [String: Any] {
        let name = "BetterTeX-\(version)-macOS-\(arch).zip"
        return ["name": name, "size": 1234, "digest": "sha256:" + String(repeating: "a", count: 64), "browser_download_url": "https://github.com/tangshunpu/BetterTeX/releases/download/v\(version)/\(name)"]
    }
    private func decodeAsset(_ object: [String: Any]) throws -> ReleaseAsset { try JSONDecoder().decode(ReleaseAsset.self, from: JSONSerialization.data(withJSONObject: object)) }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX-update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    private func makeApp(at app: URL, version: String) throws -> URL {
        let contents = app.appendingPathComponent("Contents"), executable = contents.appendingPathComponent("MacOS/BetterTeX")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = app.deletingLastPathComponent().appendingPathComponent("fixture.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        try run("/usr/bin/clang", ["-arch", AppUpdateClient.architecture, source.path, "-o", executable.path])
        let info = ["CFBundleIdentifier": "dev.bettertex.app", "CFBundleExecutable": "BetterTeX", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.2.0", "BetterTeXReleaseVersion": version, "LSMinimumSystemVersion": "13.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]); return app
    }
    private func bundleVersion(_ app: URL) throws -> String? {
        (try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any])?["BetterTeXReleaseVersion"] as? String
    }
    private func run(_ path: String, _ args: [String]) throws {
        let result = try ProcessRunner().run(path, args); guard result.succeeded else { throw BetterTeXError.message(result.output) }
    }
}

private final class UpdateURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
