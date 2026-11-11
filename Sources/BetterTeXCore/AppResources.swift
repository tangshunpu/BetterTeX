import Foundation

private final class ResourceBundleMarker {}

/// SwiftPM's generated Bundle.module traps when packaging is incomplete. Keep failure recoverable.
enum AppResources {
    static let bundle: Bundle? = {
        var roots = [Bundle.main.resourceURL, Bundle(for: ResourceBundleMarker.self).resourceURL, Bundle.main.bundleURL]
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] { roots.insert(URL(fileURLWithPath: path), at: 0) }
        #endif
        return locate(in: roots.compactMap { $0 })
    }()

    static func locate(in roots: [URL]) -> Bundle? {
        roots.lazy.compactMap { Bundle(url: $0.appendingPathComponent("BetterTeX_BetterTeXCore.bundle")) }.first
    }

    static func requiredURL(_ name: String, fileExtension ext: String, in bundle: Bundle? = bundle) throws -> URL {
        guard let url = bundle?.url(forResource: name, withExtension: ext), FileManager.default.isReadableFile(atPath: url.path) else {
            throw BetterTeXError.message(L10n.tr("应用缺少必要资源（\(name + "." + ext)），请重新安装 BetterTeX。"))
        }
        return url
    }
}
