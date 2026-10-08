import Foundation

/// Runs blocking work, such as processes, SSH commands, Herdr socket requests and file reads, on
/// a thread of its own. Swift's cooperative pool has only a thread per core, shared by every async
/// task in the app, so a few slow commands waiting there would stall unrelated work.
///
/// Each call gets a new thread rather than a dispatch queue: the system caps the threads of
/// non-overcommitting queues, and the commands this runs are far slower to start than a thread.
/// Like the detached tasks it replaces, the work is not interrupted when the caller is cancelled;
/// callers check `Task.isCancelled` once it returns.
enum BlockingWork {
    static func run<Value: Sendable>(priority: TaskPriority = .medium,
                                     _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            start(priority) { continuation.resume(with: Result { try work() }) }
        }
    }

    static func run<Value: Sendable>(priority: TaskPriority = .medium,
                                     _ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            start(priority) { continuation.resume(returning: work()) }
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

    private static func start(_ priority: TaskPriority, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = "dev.wooloo.blocking-work"
        thread.qualityOfService = qualityOfService(for: priority)
        thread.start()
    }
}
