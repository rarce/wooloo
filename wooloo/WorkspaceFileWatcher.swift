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

/// Watches single files through kqueue, which reports a write at once, where FSEvents was seen
/// to deliver writes up to 8 s late on macOS 26, merging several into one event. The editor's
/// tabs use it. A file replaced through a rename is watched again under its path; a missing file
/// is waited for through its folder. Callbacks run on the main queue.
final class WorkspaceOpenFileWatcher {
    private let receive: (String) -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]

    init(receive: @escaping (String) -> Void) { self.receive = receive }

    func watch(_ paths: Set<String>) {
        for (path, source) in sources where !paths.contains(path) {
            source.cancel()
            sources[path] = nil
        }
        for path in paths where sources[path] == nil { arm(path) }
    }

    private func arm(_ path: String) {
        var watchesFolder = false
        var descriptor = open(path, O_EVTONLY)
        if descriptor < 0 {
            watchesFolder = true
            descriptor = open((path as NSString).deletingLastPathComponent, O_EVTONLY)
        }
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke, .link], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, !source.isCancelled else { return }
            if watchesFolder || !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                source.cancel()
                self.sources[path] = nil
                self.arm(path)
            }
            self.receive(path)
        }
        source.setCancelHandler { close(descriptor) }
        sources[path] = source
        source.resume()
    }

    func stop() {
        for source in sources.values { source.cancel() }
        sources = [:]
    }

    deinit { stop() }
}
