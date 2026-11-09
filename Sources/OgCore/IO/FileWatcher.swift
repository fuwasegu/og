import CoreServices
import Foundation

/// FSEvents stream over a directory tree with file-level events.
/// The callback receives absolute paths, coalesced (~100 ms latency).
public final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "og.filewatcher")
    private let callback: @Sendable ([String]) -> Void

    public init(root: URL, callback: @escaping @Sendable ([String]) -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var out: [String] = []
            out.reserveCapacity(count)
            for case let p as String in array { out.append(p) }
            if !out.isEmpty { watcher.callback(out) }
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, cb, &context, [root.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
