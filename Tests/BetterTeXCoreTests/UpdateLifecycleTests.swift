import XCTest
@testable import BetterTeXCore

final class UpdateLifecycleTests: XCTestCase {
    func testOrdinaryQuitAndCancelledRestartNeverLaunchInstaller() throws {
        for cancelled in [false, true] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let update = try prepared(in: root)
            var launches = 0
            let pending = PendingAppUpdate(update) { _ in launches += 1; return Process() }
            if cancelled { pending.requestRestart(); pending.cancelRestart() }
            XCTAssertFalse(try pending.startIfRequested())
            pending.discardIfNotInstalling()
            XCTAssertEqual(launches, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: update.directory.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: update.destination.path))
        }
    }

    func testExplicitRestartLaunchesOnceAndTransfersStagingOwnership() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let update = try prepared(in: root)
        var launches = 0
        let pending = PendingAppUpdate(update) { _ in launches += 1; return Process() }
        pending.requestRestart(); pending.cancelRestart()
        XCTAssertFalse(try pending.startIfRequested())
        pending.requestRestart()
        XCTAssertTrue(try pending.startIfRequested())
        XCTAssertFalse(try pending.startIfRequested())
        pending.discardIfNotInstalling()
        XCTAssertEqual(launches, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: update.directory.path))
    }

    func testFailedLaunchRequiresAnotherExplicitRestart() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        let pending = PendingAppUpdate(try prepared(in: root)) { _ in
            attempts += 1
            if attempts == 1 { throw BetterTeXError.message("failed launch") }
            return Process()
        }
        pending.requestRestart()
        XCTAssertThrowsError(try pending.startIfRequested())
        XCTAssertFalse(try pending.startIfRequested())
        XCTAssertEqual(attempts, 1)
        pending.requestRestart()
        XCTAssertTrue(try pending.startIfRequested())
        XCTAssertEqual(attempts, 2)
    }

    func testCleanupOnlyRemovesOwnedStaleIdleStagingWithoutBackups() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("BetterTeX.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let cutoff = Date().addingTimeInterval(-86_400), stale = cutoff.addingTimeInterval(-3600)
        func stage(destination: URL? = nil, createdAt: Date? = nil, ownerPID: Int32 = 333) throws -> URL {
            let folder = root.appendingPathComponent(UpdateStaging.prefix + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try UpdateStaging.record(folder, destination: destination ?? target, createdAt: createdAt ?? stale, ownerPID: ownerPID)
            return folder
        }
        let abandoned = try stage(), deadHelper = try stage()
        try Data("444\n".utf8).write(to: deadHelper.appendingPathComponent("installer.pid"))
        let activeOwner = try stage(ownerPID: 111), activeHelper = try stage()
        try Data("222\n".utf8).write(to: activeHelper.appendingPathComponent("installer.pid"))
        let recent = try stage(createdAt: Date()), backup = try stage(), unknown = try stage(), otherApp = try stage(destination: root.appendingPathComponent("Another.app"))
        try FileManager.default.createDirectory(at: backup.appendingPathComponent("previous.app"), withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: unknown.appendingPathComponent(UpdateStaging.recordName))
        let invalidHelper = try stage()
        try Data("not a pid".utf8).write(to: invalidHelper.appendingPathComponent("installer.pid"))
        let symlink = root.appendingPathComponent(UpdateStaging.prefix + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unknown)
        let removed = UpdateStaging.cleanup(for: target, olderThan: cutoff, isRunning: { [111, 222].contains($0) })
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), Set([abandoned, deadHelper].map(\.lastPathComponent)))
        for retained in [target, activeOwner, activeHelper, recent, backup, unknown, otherApp, invalidHelper, symlink] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path), retained.path)
        }
    }

    func testInstallerTimeoutDiscardsOnlyUninstalledStaging() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let update = try prepared(in: root)
        try Data("old".utf8).write(to: update.destination.appendingPathComponent("marker"))
        let process = try UpdateInstaller.installerProcess(update, parentPID: ProcessInfo.processInfo.processIdentifier,
                                                           result: root.appendingPathComponent("result"), opener: "/usr/bin/false", waitAttempts: 1)
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: update.directory.path))
        XCTAssertEqual(try String(contentsOf: update.destination.appendingPathComponent("marker")), "old")
    }

    func testAutomaticPreferenceDoesNotFreezePrereleaseDefaults() throws {
        let name = "BetterTeX.PreferenceTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(UpdatePreferences.includesPrereleases(current: "0.1.0-alpha.2", in: defaults))
        UpdatePreferences.setAutomatic(false, in: defaults)
        XCTAssertNil(defaults.object(forKey: UpdatePreferences.prereleasesKey))
        XCTAssertFalse(UpdatePreferences.includesPrereleases(current: "0.1.0", in: defaults))
        UpdatePreferences.setIncludesPrereleases(true, in: defaults)
        XCTAssertFalse(UpdatePreferences.automatic(in: defaults))
        XCTAssertTrue(UpdatePreferences.includesPrereleases(current: "0.1.0", in: defaults))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeX-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); return root
    }
    private func prepared(in root: URL) throws -> PreparedAppUpdate {
        let staging = root.appendingPathComponent(UpdateStaging.prefix + UUID().uuidString), target = root.appendingPathComponent("BetterTeX.app")
        let app = staging.appendingPathComponent("BetterTeX.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return PreparedAppUpdate(directory: staging, application: app, destination: target)
    }
}
