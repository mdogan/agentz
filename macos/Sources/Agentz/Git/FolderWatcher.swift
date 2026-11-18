import CoreServices
import Foundation
import AgentzCore

/// Calls `onChange` on the main queue when something changes in one of
/// the folders or below them, except in `ignoring`. Changes close
/// together come as one call.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let ignoring: [String]
    private let onChange: ([String]?) -> Void

    convenience init(_ paths: [String], ignoring: [String], onChange: @escaping () -> Void) {
        self.init(paths, ignoring: ignoring, fileEvents: false) { _ in onChange() }
    }

    init(_ paths: [String], ignoring: [String], fileEvents: Bool, onChange: @escaping ([String]?) -> Void) {
        self.ignoring = ignoring
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let lost = (0..<count).contains { flags[$0] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
            if lost { watcher.onChange(nil) } else { watcher.changed(changed) }
        }
        // The first change comes at once, then the ones after it
        // gathered for 0.3 seconds.
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            | (fileEvents ? kFSEventStreamCreateFlagFileEvents : 0)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(flags)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func changed(_ paths: [String]) {
        let relevant = paths.filter { path in !ignoring.contains { pathStarts(path, with: $0) } }
        if !relevant.isEmpty { onChange(relevant) }
    }
}
