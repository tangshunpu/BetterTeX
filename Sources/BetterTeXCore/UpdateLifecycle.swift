import Foundation
import Darwin

/// A prepared download alone never authorizes installation during a normal quit.
public final class PendingAppUpdate {
    private let update: PreparedAppUpdate
    private let launch: (PreparedAppUpdate) throws -> Process
    private var restartRequested = false
    private var installer: Process?

    public init(_ update: PreparedAppUpdate) {
        self.update = update; launch = { try UpdateInstaller.launch($0) }
    }
    init(_ update: PreparedAppUpdate, launch: @escaping (PreparedAppUpdate) throws -> Process) {
        self.update = update; self.launch = launch
    }
    public func requestRestart() { restartRequested = true }
    public func cancelRestart() { restartRequested = false }
    @discardableResult public func startIfRequested() throws -> Bool {
        guard restartRequested, installer == nil else { return false }
        restartRequested = false // A failed/cancelled attempt needs another explicit user action.
        installer = try launch(update)
        return true
    }
    public func discardIfNotInstalling() {
        if installer == nil { update.discard() }
    }
}

/// Only directories with our ownership record can be collected. Recovery backups are never removed.
public enum UpdateStaging {
    static let prefix = ".BetterTeX-update-"
    static let recordName = "staging.json"
    struct Record: Codable {
        let destination: String
        let createdAt: Date
        let ownerPID: Int32
    }
    static func record(_ directory: URL, destination: URL, createdAt: Date = Date(), ownerPID: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let record = Record(destination: destination.resolvingSymlinksInPath().path, createdAt: createdAt, ownerPID: ownerPID)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(recordName), options: .atomic)
    }

    @discardableResult public static func cleanup(for destination: URL, olderThan cutoff: Date = Date().addingTimeInterval(-86_400)) -> [URL] {
        cleanup(for: destination, olderThan: cutoff, isRunning: processIsRunning)
    }
    static func cleanup(for destination: URL, olderThan cutoff: Date, isRunning: (Int32) -> Bool) -> [URL] {
        let fm = FileManager.default, target = destination.resolvingSymlinksInPath()
        guard let directories = try? fm.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil) else { return [] }
        var removed: [URL] = []
        for directory in directories {
            let name = directory.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  let attributes = try? fm.attributesOfItem(atPath: directory.path), attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let data = smallRegularFile(directory.appendingPathComponent(recordName)),
                  let record = try? JSONDecoder().decode(Record.self, from: data), record.destination == target.path,
                  record.createdAt < cutoff, record.ownerPID > 0, !isRunning(record.ownerPID),
                  (try? fm.attributesOfItem(atPath: directory.appendingPathComponent("previous.app").path)) == nil else { continue }
            let helper = directory.appendingPathComponent("installer.pid")
            if (try? fm.attributesOfItem(atPath: helper.path)) != nil {
                guard let data = smallRegularFile(helper), let value = String(data: data, encoding: .utf8),
                      let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, !isRunning(pid) else { continue }
            }
            do { try fm.removeItem(at: directory); removed.append(directory) } catch { /* Leave inaccessible paths for a later launch. */ }
        }
        return removed
    }
    private static func smallRegularFile(_ url: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 4096 else { return nil }
        return try? Data(contentsOf: url)
    }
    private static func processIsRunning(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}
