import Foundation
import os

/// Splits a process's output into lines across reads. EOF is terminal: appends racing with
/// `finish` either contribute before it, or are ignored after it. UTF-8 bytes stay buffered
/// until a whole line (or the final tail) is available, including across split code points.
final class RemoteAccessLineBuffer: Sendable {
    private struct State: Sendable {
        var pending = Data()
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ data: Data) -> [String] {
        state.withLock { state in
            guard !state.finished else { return [] }
            state.pending.append(data)
            guard let last = state.pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
            let complete = state.pending[..<last]
            state.pending = Data(state.pending[(last + 1)...])
            return String(decoding: complete, as: UTF8.self).components(separatedBy: "\n")
        }
    }

    /// The last line, which may lack a newline, at EOF; nil after the first call.
    func finish() -> [String]? {
        state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            defer { state.pending = Data() }
            return state.pending.isEmpty ? [] : [String(decoding: state.pending, as: UTF8.self)]
        }
    }
}
