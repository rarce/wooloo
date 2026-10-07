import AppKit
import CodeEditSourceEditor

/// The Git change bars beside the editor's line numbers. As in VS Code and Zed, the text being
/// edited is diffed against the index, so the bars show unsaved and unstaged changes as you type;
/// changes that are already staged (index differs from HEAD) are drawn as outlines, like Zed.
enum EditorLineChanges {
    /// Above this many inserted plus removed lines, the changed middle of the file is marked as
    /// one hunk instead of searching for the smallest edit, which costs O(D²) memory.
    static let maximumEditDistance = 1_000

    /// Changes of `text` for its Git bases, sorted by line. Nothing when the index has no version
    /// of the file (untracked, ignored, or outside a repository).
    static func changes(text: String, head: String?, index: String?) -> [GutterView.LineChange] {
        guard let index else { return [] }
        let unstaged = hunks(from: index, to: text)
        guard head != index else { return unstaged }
        // Hunks against HEAD that no unstaged hunk touches are entirely staged.
        let all = hunks(from: head ?? "", to: text)
        var result = all.map { hunk in
            var hunk = hunk
            hunk.isStaged = !unstaged.contains { touches($0, hunk) }
            return hunk
        }
        // Unstaged hunks with no HEAD hunk, e.g. a staged change reverted in the editor.
        result += unstaged.filter { hunk in !all.contains { touches($0, hunk) } }
        return result.sorted { $0.line < $1.line }
    }

    private static func touches(_ a: GutterView.LineChange, _ b: GutterView.LineChange) -> Bool {
        a.line < b.line + max(b.count, 1) && b.line < a.line + max(a.count, 1)
    }

    /// Line hunks turning `base` into `text`, positioned in `text`'s lines.
    static func hunks(from base: String, to text: String) -> [GutterView.LineChange] {
        let old = base.split(separator: "\n", omittingEmptySubsequences: false)
        let new = text.split(separator: "\n", omittingEmptySubsequences: false)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let oldMiddle = old[prefix..<(old.count - suffix)]
        let newMiddle = new[prefix..<(new.count - suffix)]
        if oldMiddle.isEmpty && newMiddle.isEmpty { return [] }

        // Compare numbered lines instead of strings.
        var numbers: [Substring: Int32] = [:]
        let number = { (line: Substring) -> Int32 in
            if let value = numbers[line] { return value }
            let value = Int32(numbers.count)
            numbers[line] = value
            return value
        }
        let a = oldMiddle.map(number), b = newMiddle.map(number)
        var removed = [Bool](repeating: true, count: a.count)
        var inserted = [Bool](repeating: true, count: b.count)
        _ = shortestEdit(a, b, maximumCost: maximumEditDistance, removed: &removed, inserted: &inserted)

        var result: [GutterView.LineChange] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let start = j
            var removedCount = 0, insertedCount = 0
            while (i < a.count && removed[i]) || (j < b.count && inserted[j]) {
                if i < a.count && removed[i] { i += 1; removedCount += 1 } else { j += 1; insertedCount += 1 }
            }
            if removedCount == 0 && insertedCount == 0 {
                i += 1; j += 1
                continue
            }
            let kind: GutterView.LineChange.Kind = insertedCount == 0 ? .deleted : (removedCount == 0 ? .added : .modified)
            result.append(.init(line: prefix + start, count: insertedCount, kind: kind, isStaged: false))
        }
        return result
    }

    /// Myers' O(ND) diff. Clears `removed` and `inserted` for the lines it keeps, and returns false
    /// (keeping nothing) when more than `maximumCost` lines differ.
    private static func shortestEdit(_ a: [Int32], _ b: [Int32], maximumCost: Int,
                                     removed: inout [Bool], inserted: inout [Bool]) -> Bool {
        let n = a.count, m = b.count
        let limit = min(n + m, maximumCost)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        // trace[d] holds v[k] for k in -d-1...d+1 before step d.
        var trace: [[Int]] = []
        var found: Int?
        search: for d in 0...limit {
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
                    ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { found = d; break search }
            }
        }
        guard let cost = found else { return false }

        var x = n, y = m
        for d in stride(from: cost, to: 0, by: -1) {
            let previous = trace[d]
            let at = { (k: Int) in previous[k + d + 1] }
            let k = x - y
            let down = k == -d || (k != d && at(k - 1) < at(k + 1))
            let previousK = down ? k + 1 : k - 1
            let previousX = at(previousK), previousY = previousX - previousK
            while x > previousX && y > previousY {
                x -= 1; y -= 1
                removed[x] = false; inserted[y] = false
            }
            if down { inserted[previousY] = true } else { removed[previousX] = true }
            x = previousX; y = previousY
        }
        while x > 0 && y > 0 {
            x -= 1; y -= 1
            removed[x] = false; inserted[y] = false
        }
        return true
    }
}

/// Keeps the editor's gutter change bars current: the diff runs off the main thread shortly after
/// typing pauses, and again when the Git bases are reloaded.
final class EditorLineChangeCoordinator: TextViewCoordinator {
    private weak var controller: TextViewController?
    private var bases: (head: String?, index: String?)?
    private var colors: (added: NSColor, modified: NSColor, deleted: NSColor)?
    private var pending: DispatchWorkItem?
    private var generation = 0
    private static let queue = DispatchQueue(label: "dev.wooloo.line-changes", qos: .userInitiated)

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        // CodeEdit calls this before loadView creates the gutter. Restore cached colors
        // on the next main-queue turn, after the editor has finished loading.
        update(after: 0)
    }

    func textViewDidChangeText(controller: TextViewController) {
        update(after: 0.2)
    }

    func destroy() {
        pending?.cancel()
        generation += 1
        controller = nil
    }

    func setBases(head: String?, index: String?) {
        bases = (head, index)
        update(after: 0)
    }

    func setColors(added: NSColor, modified: NSColor, deleted: NSColor) {
        colors = (added, modified, deleted)
        controller?.gutterView?.lineChangeColors = (added, modified, deleted)
    }

    private func update(after delay: TimeInterval) {
        pending?.cancel()
        generation += 1
        let generation = generation
        // Reading the text copies it, so wait until typing pauses.
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, let controller = self.controller else { return }
            if let colors { controller.gutterView?.lineChangeColors = colors }
            guard let bases else { return }
            let text = controller.textView.string
            Self.queue.async {
                let changes = EditorLineChanges.changes(text: text, head: bases.head, index: bases.index)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.controller?.gutterView?.lineChanges = changes
                }
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

/// Watches a local Git directory the way VS Code and Zed watch `.git/index`. Git writes the index
/// and HEAD to a lock file and renames it into place, so the directory is watched rather than the
/// files, whose descriptors would keep pointing at the replaced inode.
final class GitDirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    /// `onChange` runs on the main queue once a burst of writes settles.
    init?(directory: String, onChange: @escaping () -> Void) {
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            pending?.cancel()
            let item = DispatchWorkItem(block: onChange)
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        pending?.cancel()
        source.cancel()
    }
}
