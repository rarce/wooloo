import AppKit
import Foundation

/// What was typed in Go to File: space-separated terms that must all match a path, then an
/// optional `:line` or `:line:column` to place the cursor.
struct QuickOpenQuery: Equatable {
    let terms: [String]
    /// 1-based.
    let line: Int?
    /// 1-based.
    let column: Int?

    init(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var numbers: [Int] = []
        while numbers.count < 2, let colon = rest.lastIndex(of: ":") {
            let tail = rest[rest.index(after: colon)...]
            // A trailing colon is a number still being typed.
            if !tail.isEmpty {
                guard tail.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(tail) else { break }
                numbers.insert(number, at: 0)
            }
            rest = rest[..<colon]
        }
        terms = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        line = numbers.first
        column = numbers.count > 1 ? numbers[1] : nil
    }
}

/// File paths prepared for matching: their bytes in one buffer, with ASCII letters lowercased in
/// a copy, so searching 200,000 paths allocates nothing per path.
struct QuickOpenIndex: Sendable {
    let paths: [String]
    fileprivate let bytes: [UInt8]
    fileprivate let folded: [UInt8]
    /// Where each path starts in `bytes`, plus the end of the last one.
    fileprivate let starts: [Int]
    /// Where each path's file name starts in `bytes`.
    fileprivate let nameStarts: [Int]
    private let positions: [String: Int]

    init(_ paths: [String]) {
        self.paths = paths
        var bytes: [UInt8] = []
        var starts: [Int] = []
        var nameStarts: [Int] = []
        bytes.reserveCapacity(paths.count * 48)
        starts.reserveCapacity(paths.count + 1)
        nameStarts.reserveCapacity(paths.count)
        for path in paths {
            starts.append(bytes.count)
            var nameStart = bytes.count
            for byte in path.utf8 {
                bytes.append(byte)
                if byte == UInt8(ascii: "/") { nameStart = bytes.count }
            }
            nameStarts.append(nameStart)
        }
        starts.append(bytes.count)
        self.bytes = bytes
        folded = bytes.map(QuickOpenMatcher.fold)
        self.starts = starts
        self.nameStarts = nameStarts
        positions = Dictionary(paths.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func contains(_ path: String) -> Bool { positions[path] != nil }
}

struct QuickOpenMatch: Equatable, Sendable {
    let path: String
    let score: Int
    /// UTF-8 offsets in `path` of the matched characters.
    let positions: [Int]
    /// Shown recently in the Space; recent matches are listed first.
    let isRecent: Bool
}

/// Fuzzy path matching for Go to File. Each query term must appear in the path in order, not
/// necessarily contiguously; matches score higher when they are contiguous, start words, or
/// fall in the file name.
enum QuickOpenMatcher {
    static func fold(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }

    /// The best `limit` matches, recent files first, or nil when the task was cancelled. An
    /// empty query lists the recent files in order.
    static func match(_ query: QuickOpenQuery, in index: QuickOpenIndex, recents: [String],
                      limit: Int = 100) -> [QuickOpenMatch]? {
        if query.terms.isEmpty {
            return recents.filter(index.contains).prefix(limit)
                .map { QuickOpenMatch(path: $0, score: 0, positions: [], isRecent: true) }
        }
        let recent = Set(recents)
        let terms = query.terms.map { $0.utf8.map(fold) }
        var scored: [(path: Int, score: Int, isRecent: Bool)] = []
        var positions: [Int] = []
        let cancelled: Bool = index.folded.withUnsafeBufferPointer { folded in
            index.bytes.withUnsafeBufferPointer { bytes in
                for path in index.paths.indices {
                    if path & 8191 == 0, Task.isCancelled { return true }
                    guard let score = score(path, terms: terms, in: index, folded: folded, bytes: bytes,
                                            positions: &positions) else { continue }
                    scored.append((path, score, recent.contains(index.paths[path])))
                }
                return false
            }
        }
        if cancelled { return nil }
        scored.sort { a, b in
            if a.isRecent != b.isRecent { return a.isRecent }
            if a.score != b.score { return a.score > b.score }
            let lengthA = index.starts[a.path + 1] - index.starts[a.path]
            let lengthB = index.starts[b.path + 1] - index.starts[b.path]
            return lengthA != lengthB ? lengthA < lengthB : index.paths[a.path] < index.paths[b.path]
        }
        return index.folded.withUnsafeBufferPointer { folded in
            index.bytes.withUnsafeBufferPointer { bytes in
                scored.prefix(limit).map { item in
                    _ = score(item.path, terms: terms, in: index, folded: folded, bytes: bytes, positions: &positions)
                    let start = index.starts[item.path]
                    return QuickOpenMatch(path: index.paths[item.path], score: item.score,
                                          positions: Set(positions).sorted().map { $0 - start }, isRecent: item.isRecent)
                }
            }
        }
    }

    /// The score of one path for every term, or nil when a term is missing; `positions`
    /// receives the matched offsets in the index's buffer.
    private static func score(_ path: Int, terms: [[UInt8]], in index: QuickOpenIndex,
                              folded: UnsafeBufferPointer<UInt8>, bytes: UnsafeBufferPointer<UInt8>,
                              positions: inout [Int]) -> Int? {
        positions.removeAll(keepingCapacity: true)
        let start = index.starts[path], end = index.starts[path + 1], nameStart = index.nameStarts[path]
        var total = -(end - start) / 8
        for term in terms {
            // A term found in the file name beats the same letters spread over folders.
            if let score = score(term, from: nameStart, to: end, pathStart: start,
                                 folded: folded, bytes: bytes, positions: &positions) {
                total += score + 40
                // The whole name, or the name without its extension.
                var stemEnd = nameStart + 1
                while stemEnd < end, bytes[stemEnd] != UInt8(ascii: ".") { stemEnd += 1 }
                if positions[positions.count - term.count] == nameStart, positions[positions.count - 1] == nameStart + term.count - 1,
                   term.count == end - nameStart || term.count == stemEnd - nameStart {
                    total += 60
                }
            } else if let score = score(term, from: start, to: end, pathStart: start,
                                        folded: folded, bytes: bytes, positions: &positions) {
                total += score
            } else {
                return nil
            }
        }
        return total
    }

    /// Scores `term` within `from..<to`: finds where its first match ends, then the shortest
    /// window ending there, then takes the earliest letters in that window.
    private static func score(_ term: [UInt8], from: Int, to: Int, pathStart: Int,
                              folded: UnsafeBufferPointer<UInt8>, bytes: UnsafeBufferPointer<UInt8>,
                              positions: inout [Int]) -> Int? {
        guard !term.isEmpty else { return 0 }
        var next = 0
        var last = from
        var offset = from
        while offset < to, next < term.count {
            if folded[offset] == term[next] {
                next += 1
                last = offset
            }
            offset += 1
        }
        guard next == term.count else { return nil }
        var first = last
        var previous = term.count - 1
        offset = last
        while offset >= from {
            if folded[offset] == term[previous] {
                first = offset
                if previous == 0 { break }
                previous -= 1
            }
            offset -= 1
        }
        var score = -min(first - from, 10)
        var matched = 0
        var previousMatch = -2
        offset = first
        while matched < term.count {
            if folded[offset] == term[matched] {
                score += 16
                if offset == previousMatch + 1 {
                    score += 24
                } else if previousMatch >= 0 {
                    score -= min(offset - previousMatch - 1, 12) * 2
                }
                if offset == pathStart || bytes[offset - 1] == UInt8(ascii: "/") {
                    score += 24
                } else if isSeparator(bytes[offset - 1]) {
                    score += 20
                } else if isLower(bytes[offset - 1]) && isUpper(bytes[offset]) {
                    score += 18
                }
                positions.append(offset)
                previousMatch = offset
                matched += 1
            }
            offset += 1
        }
        return score
    }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: " ")
    }

    private static func isLower(_ byte: UInt8) -> Bool { byte >= 97 && byte <= 122 }
    private static func isUpper(_ byte: UInt8) -> Bool { byte >= 65 && byte <= 90 }
}

/// Go to File (⌘P): fuzzy search over a Space's files, with recently shown files first. The
/// files are read once per location and read again behind the results each time it opens.
@MainActor
final class QuickOpenModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    @Published private(set) var results: [QuickOpenMatch] = []
    @Published var selection = 0
    @Published private(set) var isIndexing = false
    /// True when the Space has more files than the listing keeps.
    @Published private(set) var isTruncated = false
    @Published private(set) var error: String?
    @Published private(set) var location: WorkspaceFileLocation?

    /// Reads a location's files; tests replace it.
    var loadFiles: @Sendable (WorkspaceFileLocation) throws -> (files: [String], truncated: Bool) = {
        try WorkspaceFiles.quickOpenFiles(at: $0)
    }

    private var recents: [String] = []
    private var index: QuickOpenIndex?
    private var indexIdentity: String?
    private var loadGeneration = 0
    private var matchGeneration = 0
    private var matchTask: Task<Void, Never>?
    private weak var previousResponder: NSResponder?

    var selectedMatch: QuickOpenMatch? { results.indices.contains(selection) ? results[selection] : nil }

    /// Opens on a location. `recents` are its files shown most recently first; `current`, the
    /// one shown now, goes last so that ⌘P ↩ switches back to the previous file.
    func present(at location: WorkspaceFileLocation, recents: [String], current: String?) {
        previousResponder = NSApp?.keyWindow?.firstResponder
        if location.identity != indexIdentity {
            index = nil
            indexIdentity = location.identity
            isTruncated = false
        }
        self.location = location
        self.recents = recents.filter { $0 != current } + (current.map { [$0] } ?? [])
        error = nil
        isPresented = true
        if query.isEmpty { refresh() } else { query = "" }
        loadIndex(location)
    }

    /// Closes, giving the keyboard back to what had it unless a file is being opened.
    func dismiss(restoringFocus: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        matchTask?.cancel()
        if restoringFocus, let view = previousResponder as? NSView, let window = view.window {
            window.makeFirstResponder(view)
        }
        previousResponder = nil
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = ((selection + delta) % results.count + results.count) % results.count
    }

    private func loadIndex(_ location: WorkspaceFileLocation) {
        loadGeneration += 1
        let generation = loadGeneration
        isIndexing = true
        let load = loadFiles
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { () -> (QuickOpenIndex, Bool) in
                    let listing = try load(location)
                    return (QuickOpenIndex(listing.files), listing.truncated)
                }
            }.value
            guard generation == loadGeneration else { return }
            isIndexing = false
            switch outcome {
            case .success(let (newIndex, truncated)):
                isTruncated = truncated
                guard newIndex.paths != index?.paths else { return }
                index = newIndex
                refresh(keepingSelection: true)
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    /// Matches the query again. Until the first listing arrives only recent files are searched.
    private func refresh(keepingSelection: Bool = false) {
        matchTask?.cancel()
        matchGeneration += 1
        let generation = matchGeneration
        let selectedPath = keepingSelection ? selectedMatch?.path : nil
        let query = QuickOpenQuery(self.query)
        let recents = recents
        let index = index ?? QuickOpenIndex(recents)
        if query.terms.isEmpty || index.paths.count < 2_000 {
            apply(QuickOpenMatcher.match(query, in: index, recents: recents) ?? [], selectedPath: selectedPath)
            return
        }
        matchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let matches = QuickOpenMatcher.match(query, in: index, recents: recents) else { return }
            await self?.apply(matches, selectedPath: selectedPath, generation: generation)
        }
    }

    private func apply(_ matches: [QuickOpenMatch], selectedPath: String?, generation: Int? = nil) {
        if let generation, generation != matchGeneration { return }
        results = matches
        selection = selectedPath.flatMap { path in matches.firstIndex { $0.path == path } } ?? 0
    }
}
