import Foundation
import CoreServices

final class ProjectWatcher {
    private var stream: FSEventStreamRef?
    var onChange: (() -> Void)?
    func start(_ url: URL) {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            if paths.prefix(count).contains(where: { !$0.contains("/.bettertex/") && !$0.hasSuffix("/.bettertex") && !$0.contains("/.git/") && !$0.hasSuffix("/.git") }) { watcher.onChange?() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.6, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); FSEventStreamStart(stream) }
    }
    func stop() { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }; stream = nil }
    deinit { stop() }
}
