import CoreServices
import Darwin
import Foundation

/// One recursive stream for the Space and its Git metadata, including metadata outside a
/// linked worktree. Callbacks run on the main queue; stopping releases the callback context.
final class WorkspaceFileWatcher {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags

        var requiresRescan: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0
        }
    }

    private final class Callback {
        let receive: ([Event]) -> Void
        init(_ receive: @escaping ([Event]) -> Void) { self.receive = receive }
    }

    private var stream: FSEventStreamRef?

    /// Foundation can turn /private/tmp into /tmp, while FSEvents reports /private/tmp.
    /// POSIX realpath uses the filesystem's spelling, so both sides compare identically.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    init?(paths: [String], receive: @escaping ([Event]) -> Void) {
        let paths = Array(Set(paths.map(Self.canonicalPath))).sorted()
        guard !paths.isEmpty else { return nil }
        let callback = Callback(receive)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            callback.receive((0..<count).map { Event(path: String(cString: paths[$0]), flags: flags[$0]) })
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer))
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
