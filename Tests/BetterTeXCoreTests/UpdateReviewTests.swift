import XCTest
import CryptoKit
@testable import BetterTeXCore

final class UpdateReviewTests: XCTestCase {
    func testPublisherSignatureRejectsTamperingWrongKeyAndMalformedSignature() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("update.zip")
        try Data("original archive".utf8).write(to: archive)
        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
        let publicKey = base64(key.publicKey.rawRepresentation)
        let signature = base64(try key.signature(for: UpdateSignature.message(for: archive)))
        XCTAssertNoThrow(try UpdateSignature.verify(archive: archive, signature: signature, publicKey: publicKey))
        XCTAssertThrowsError(try UpdateSignature.verify(archive: archive, signature: signature, publicKey: base64(other.publicKey.rawRepresentation)))
        for invalid in [Data(), Data("not base64!".utf8), base64(Data(repeating: 0, count: 64)), Data(repeating: 65, count: 2048)] {
            XCTAssertThrowsError(try UpdateSignature.verify(archive: archive, signature: invalid, publicKey: publicKey))
        }
        try Data("tampered archive".utf8).write(to: archive)
        XCTAssertThrowsError(try UpdateSignature.verify(archive: archive, signature: signature, publicKey: publicKey))
        let signatureURL = folder.appendingPathComponent("update.zip.sig")
        try signature.write(to: signatureURL)
        let target = folder.appendingPathComponent("BetterTeX.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertThrowsError(try UpdateInstaller.prepare(archive: archive, signature: signatureURL, release: release(assets: []), destination: target, publicKey: publicKey))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".BetterTeX-update-") }.isEmpty)
    }

    func testSignatureAssetMustBeTheMatchingTrustedCompanion() throws {
        let zip = asset(name: "BetterTeX-1.0.0-macOS-arm64.zip")
        let unsigned = try release(assets: [zip])
        let archive = try XCTUnwrap(unsigned.asset(architecture: "arm64"))
        XCTAssertNil(unsigned.signatureAsset(for: archive))
        var signature = asset(name: archive.name + ".sig"); signature["size"] = 89
        XCTAssertNotNil(try release(assets: [zip, signature]).signatureAsset(for: archive))
        for (field, value) in [("size", 2048 as Any), ("browser_download_url", "https://evil.example/update.sig" as Any), ("name", "other.zip.sig" as Any)] {
            var invalid = signature; invalid[field] = value
            XCTAssertNil(try release(assets: [zip, invalid]).signatureAsset(for: archive))
        }
    }

    func testMissingResourcesReturnErrorsAndLocalizationFallsBack() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(AppResources.locate(in: [folder]))
        XCTAssertThrowsError(try UpdateInstaller.scriptURL(in: nil))
        XCTAssertThrowsError(try AppResources.requiredURL("UpdateSigningPublicKey", fileExtension: "txt", in: nil))
        let localizer = Localizer(language: .english, preferredLanguages: ["en"], resourceBundle: nil)
        XCTAssertEqual(localizer.string("Missing resource %@ \("details")"), "Missing resource %@ details")
        XCTAssertEqual(localizer.string("Untranslated fallback"), "Untranslated fallback")
        XCTAssertNotNil(AppResources.bundle)
        XCTAssertNoThrow(try UpdateInstaller.scriptURL())
    }

    func testFailedRollbackDoesNotReopenNewAppAndKeepsOldBackup() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("BetterTeX.app"), staging = folder.appendingPathComponent("stage")
        let next = staging.appendingPathComponent("BetterTeX.app"), result = folder.appendingPathComponent("result")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: next.appendingPathComponent("marker"))
        let opener = folder.appendingPathComponent("opener.sh")
        let script = """
        #!/bin/sh
        root=$(/usr/bin/dirname "$2")
        printf 'launch\\n' >> "$root/launches"
        /bin/chmod 500 "$root/stage"
        exit 1
        """
        try Data(script.utf8).write(to: opener)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: opener.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path) }
        let update = PreparedAppUpdate(directory: staging, application: next, destination: target)
        let process = try UpdateInstaller.installerProcess(update, parentPID: Int32.max, result: result, opener: opener.path)
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("launches")), "launch\n")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("marker")), "new")
        let backup = staging.appendingPathComponent("previous.app")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("marker")), "old")
        XCTAssertEqual(try String(contentsOf: result), "recovery-required\n\(backup.path)\n")
    }

    func testSigningToolInteroperatesAndRefusesKeyReplacement() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tool = root.appendingPathComponent("script/sign_update.swift")
        let privateKey = folder.appendingPathComponent("keys/private.key"), publicKey = folder.appendingPathComponent("public.txt")
        let archive = folder.appendingPathComponent("update.zip")
        try Data("archive signed by the release tool".utf8).write(to: archive)
        func run(_ arguments: [String]) throws -> CommandResult { try ProcessRunner().run("/usr/bin/swift", [tool.path] + arguments) }
        XCTAssertTrue(try run(["generate", privateKey.path, publicKey.path]).succeeded)
        let attributes = try FileManager.default.attributesOfItem(atPath: privateKey.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try run(["generate", privateKey.path, publicKey.path]).succeeded)
        XCTAssertTrue(try run(["sign", archive.path, privateKey.path, publicKey.path]).succeeded)
        let signature = archive.appendingPathExtension("sig")
        XCTAssertNoThrow(try UpdateSignature.verify(archive: archive, signature: Data(contentsOf: signature), publicKey: Data(contentsOf: publicKey)))
        XCTAssertTrue(try run(["verify", archive.path, signature.path, publicKey.path]).succeeded)
        try Data("different bytes".utf8).write(to: archive)
        XCTAssertFalse(try run(["verify", archive.path, signature.path, publicKey.path]).succeeded)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX-review-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    private func base64(_ data: Data) -> Data { Data(data.base64EncodedString().utf8) }
    private func asset(name: String) -> [String: Any] {
        ["name": name, "size": 1234, "digest": "sha256:" + String(repeating: "a", count: 64), "browser_download_url": "https://github.com/tangshunpu/BetterTeX/releases/download/v1.0.0/\(name)"]
    }
    private func release(assets: [[String: Any]]) throws -> AppRelease {
        try JSONDecoder().decode(AppRelease.self, from: JSONSerialization.data(withJSONObject: ["tag_name": "v1.0.0", "draft": false, "prerelease": false, "assets": assets]))
    }
}
