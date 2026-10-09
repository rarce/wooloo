import Foundation

/// Runs blocking work, such as processes, SSH commands, Herdr socket requests and file reads, on
/// a thread of its own. Swift's cooperative pool has only a thread per core, shared by every async
/// task in the app, so a few slow commands waiting there would stall unrelated work.
///
/// Each call gets a new thread rather than a dispatch queue: the system caps the threads of
/// non-overcommitting queues, and the commands this runs are far slower to start than a thread.
///
/// Each machine has a limit of its own: at most `limit` calls run at once on this Mac, and at
/// most `machineLimit` on each SSH machine; the rest wait, suspended rather than holding a thread,
/// in the order they arrived. The pool used to cap them at a thread per core, and a cap still
/// matters: an SSH Space shares one ControlMaster connection, and sshd refuses more than
/// `MaxSessions` (10 by default) sessions on it, so a README with many images, read at once,
/// would fail. With a limit per machine, local loads run while a slow SSH machine holds every
/// slot of its own. Work that blocks for as long as a connection lasts, such as Herdr's event and
/// surface streams, passes `limited: false` so it never holds a slot.
///
/// Work that reaches a Space or a machine starts through `WorkspaceFiles.blocking(at:)` or
/// `WorkspaceFiles.blocking(on:)`, which take the limit from the location or machine, rather
/// than through `run` here, which counts against this Mac. An SSH command that runs in a slot of
/// another machine, such as one started with `run` alone, stops a debug build (`holdsSlot(of:)`).
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
    /// The limit on this Mac: a call per core, but at least 4, so a small Mac does not queue a
    /// refresh behind one slow command, and at most 8.
    static let limit = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))

    /// The limit on each SSH machine, whatever this Mac's core count: below sshd's default
    /// `MaxSessions` of 10 on the shared ControlMaster connection, leaving room for the few
    /// commands that reach it outside `BlockingWork`.
    static let machineLimit = 8

    /// This Mac's slots.
    static let slots = BlockingWorkLimit(limit)

    private static let machineSlotsLock = NSLock()
    private static var machineSlots: [String: BlockingWorkLimit] = [:]

    /// The slots of `machine`, made on first use.
    static func slots(for machine: BlockingWorkMachine) -> BlockingWorkLimit {
        guard case .ssh(let target) = machine else { return slots }
        return machineSlotsLock.withLock {
            if let existing = machineSlots[target] { return existing }
            let created = BlockingWorkLimit(machineLimit)
            machineSlots[target] = created
            return created
        }
    }

    private static let machineKey = "dev.wooloo.blocking-work.machine"

    /// The machine whose slot the current thread's work holds; nil outside limited work.
    static var currentMachine: BlockingWorkMachine? {
        Thread.current.threadDictionary[machineKey] as? BlockingWorkMachine
    }

    /// False when the current thread's work holds a slot of a machine other than `machine`, as
    /// when work that reaches an SSH machine was started with `run` and so counts against this
    /// Mac. True outside limited work.
    static func holdsSlot(of machine: BlockingWorkMachine) -> Bool {
        currentMachine.map { $0 == machine } ?? true
    }

    /// `priority` defaults to the calling task's priority. With a `worker`, the work runs on that
    /// worker's thread instead of a new one. `machine` picks the limit; work that reaches a Space
    /// or an SSH machine goes through `WorkspaceFiles.blocking`, which sets it.
    static func run<Value: Sendable>(priority: TaskPriority? = nil, limited: Bool = true,
                                     reaching machine: BlockingWorkMachine = .local, on worker: BlockingWorker? = nil,
                                     _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await run(qualityOfService: qualityOfService(for: priority ?? Task.currentPriority),
                      limited: limited, reaching: machine, on: worker, work)
    }

    /// Returns `Value.cancelled` instead of running `work` when cancelled. A closure returning a
    /// plain value can opt in by wrapping it in `Optional`.
    static func run<Value: BlockingWorkCancellable & Sendable>(priority: TaskPriority? = nil, limited: Bool = true,
                                                               reaching machine: BlockingWorkMachine = .local,
                                                               on worker: BlockingWorker? = nil,
                                                               _ work: @escaping @Sendable () -> Value) async -> Value {
        do {
            return try await run(qualityOfService: qualityOfService(for: priority ?? Task.currentPriority),
                                 limited: limited, reaching: machine, on: worker, work)
        } catch {
            return .cancelled
        }
    }

    /// Runs `work` at an explicit quality of service, such as `.userInteractive`, which no task
    /// priority maps to.
    static func run<Value: Sendable>(qualityOfService: QualityOfService, limited: Bool = true,
                                     reaching machine: BlockingWorkMachine = .local,
                                     name: String = "dev.wooloo.blocking-work", on worker: BlockingWorker? = nil,
                                     _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let limiter = limited ? slots(for: machine) : nil
        let held = limited ? machine : nil
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
                let result = Result { try holdingSlot(of: held, work) }
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

    /// Runs `work` with the current thread marked as holding a slot of `machine`, if any.
    private static func holdingSlot<Value>(of machine: BlockingWorkMachine?, _ work: () throws -> Value) rethrows -> Value {
        guard let machine else { return try work() }
        let dictionary = Thread.current.threadDictionary
        // A worker's queue reuses its thread, so the previous mark comes back afterwards.
        let previous = dictionary[machineKey]
        dictionary[machineKey] = machine
        defer { dictionary[machineKey] = previous }
        return try work()
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

/// The machine blocking work reaches, which picks the limit it waits for. SSH machines are told
/// apart by their target, which names the shared ControlMaster connection.
enum BlockingWorkMachine: Hashable, Sendable, CustomStringConvertible {
    case local
    case ssh(String)

    init(_ machine: HerdrMachineProfile?) {
        self = machine.map { .ssh($0.target) } ?? .local
    }

    var description: String {
        switch self {
        case .local: return "this Mac"
        case .ssh(let target): return target
        }
    }
}

/// A thread for blocking work that repeats, such as a poll, so each round does not start a thread
/// of its own. Its calls run one at a time, in order, and still take a slot of `BlockingWork`, of
/// the machine each call reaches.
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
