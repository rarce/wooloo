import Foundation

/// Runs blocking work, such as processes, SSH commands, Herdr socket requests and file reads, on
/// a thread of its own. Swift's cooperative pool has only a thread per core, shared by every async
/// task in the app, so a few slow commands waiting there would stall unrelated work.
///
/// Each call gets a new thread rather than a dispatch queue: the system caps the threads of
/// non-overcommitting queues, and the commands this runs are far slower to start than a thread.
///
/// At most `limit` calls run at once; the rest wait, suspended rather than holding a thread, in
/// the order they arrived. The pool used to cap them at a thread per core, and a cap still
/// matters: an SSH Space shares one ControlMaster connection, and sshd refuses more than
/// `MaxSessions` (10 by default) sessions on it, so a README with many images, read at once,
/// would fail. Work that blocks for as long as a connection lasts, such as Herdr's event and
/// surface streams, passes `limited: false` so it never holds a slot.
///
/// A call whose task is already cancelled, or is cancelled while it waits for a slot, does not
/// start: the throwing variant throws `CancellationError`, and the other returns the value's
/// cancelled form (a failed `Result` or `nil`). Work that has started is not interrupted; callers
/// check `Task.isCancelled` once it returns.
///
/// The synchronous APIs that block, such as `WorkspaceFiles`, `SharedLoads.value` and
/// `HerdrSocket`, are marked `@available(*, noasync)`, so calling one straight from async code is
/// a compiler warning (an error in the Swift 6 language mode). Call them inside the closure passed
/// here, which is synchronous. The check stops at any synchronous function or closure in between,
/// such as a `Result { … }` inside a `Task`, so a helper that blocks should be marked as well;
/// `BlockingWorkLoadTests` covers the models' real load paths.
enum BlockingWork {
    /// One limit for every machine, since callers pass closures that do not say which machine they
    /// reach: below sshd's default `MaxSessions` of 10, leaving room for the few loads that still
    /// run outside `BlockingWork`, and at least 4 so a small Mac does not queue a refresh behind
    /// one slow command.
    static let limit = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))

    static let slots = BlockingWorkLimit(limit)

    /// `priority` defaults to the calling task's priority. With a `worker`, the work runs on that
    /// worker's thread instead of a new one.
    static func run<Value: Sendable>(priority: TaskPriority? = nil, limited: Bool = true, on worker: BlockingWorker? = nil,
                                     _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await run(qualityOfService: qualityOfService(for: priority ?? Task.currentPriority),
                      limited: limited, on: worker, work)
    }

    /// Returns `Value.cancelled` instead of running `work` when cancelled. A closure returning a
    /// plain value can opt in by wrapping it in `Optional`.
    static func run<Value: BlockingWorkCancellable & Sendable>(priority: TaskPriority? = nil, limited: Bool = true,
                                                               on worker: BlockingWorker? = nil,
                                                               _ work: @escaping @Sendable () -> Value) async -> Value {
        do {
            return try await run(qualityOfService: qualityOfService(for: priority ?? Task.currentPriority),
                                 limited: limited, on: worker, work)
        } catch {
            return .cancelled
        }
    }

    /// Runs `work` at an explicit quality of service, such as `.userInteractive`, which no task
    /// priority maps to.
    static func run<Value: Sendable>(qualityOfService: QualityOfService, limited: Bool = true,
                                     name: String = "dev.wooloo.blocking-work", on worker: BlockingWorker? = nil,
                                     _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let limiter = limited ? slots : nil
        if let limiter {
            try await limiter.acquire()
            // Cancelled just as the slot came free.
            if Task.isCancelled {
                limiter.release()
                throw CancellationError()
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let body: @Sendable () -> Void = {
                let result = Result { try work() }
                limiter?.release()
                continuation.resume(with: result)
            }
            if let worker {
                worker.execute(qualityOfService: qualityOfService, body)
                return
            }
            let thread = Thread(block: body)
            thread.name = name
            thread.qualityOfService = qualityOfService
            thread.start()
        }
    }

    static func qualityOfService(for priority: TaskPriority) -> QualityOfService {
        switch priority.rawValue {
        case TaskPriority.high.rawValue...: return .userInitiated
        case TaskPriority.medium.rawValue...: return .default
        case TaskPriority.low.rawValue...: return .utility
        default: return .background
        }
    }
}

/// A thread for blocking work that repeats, such as a poll, so each round does not start a thread
/// of its own. Its calls run one at a time, in order, and still take a slot of `BlockingWork`.
/// A call takes its slot before it is queued, so one waiting behind another holds a slot too:
/// give each loop a worker of its own and await each call before making the next, as the
/// pane-text poll and `HostStatsMonitor` do. A call already queued runs even if its task is
/// cancelled.
///
/// It is a private serial queue: unlike the global queues, the system gives one a thread even when
/// its limit on threads for queues is reached, and keeps reusing that thread while work comes in.
final class BlockingWorker: Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    func execute(qualityOfService: QualityOfService, _ body: @escaping @Sendable () -> Void) {
        queue.async(qos: DispatchQoS(qosClass: Self.qosClass(qualityOfService), relativePriority: 0),
                    flags: .enforceQoS, execute: body)
    }

    static func qosClass(_ quality: QualityOfService) -> DispatchQoS.QoSClass {
        switch quality {
        case .userInteractive: return .userInteractive
        case .userInitiated: return .userInitiated
        case .utility: return .utility
        case .background: return .background
        default: return .default
        }
    }
}

/// A value the non-throwing `BlockingWork.run` returns when its task is cancelled before the work
/// starts.
protocol BlockingWorkCancellable {
    static var cancelled: Self { get }
}

extension Result: BlockingWorkCancellable where Failure == any Error {
    static var cancelled: Self { .failure(CancellationError()) }
}

extension Optional: BlockingWorkCancellable {
    static var cancelled: Self { nil }
}

/// A counting semaphore for async callers. Waiting suspends the task instead of blocking a
/// thread, and a cancelled task stops waiting with `CancellationError`. Waiters get slots in the
/// order they arrived.
final class BlockingWorkLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Int
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID: UInt64 = 0

    init(_ count: Int) {
        available = count
    }

    /// Tasks waiting for a slot.
    var waiting: Int { lock.withLock { waiters.count } }

    func acquire() async throws {
        let id = lock.withLock { () -> UInt64 in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                // Checked under the lock: a cancellation that came before the waiter was added
                // found nothing to remove.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if available > 0 {
                    available -= 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                lock.unlock()
                return
            }
            let continuation = waiters.remove(at: index).continuation
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            available += 1
            lock.unlock()
        } else {
            let continuation = waiters.removeFirst().continuation
            lock.unlock()
            continuation.resume()
        }
    }
}
