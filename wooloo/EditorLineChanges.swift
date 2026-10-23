import AppKit
import SwiftUI
import CodeEditTextView
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
    weak var overview: EditorGitOverviewView? {
        didSet { refreshOverview() }
    }

    private func refreshOverview() {
        overview?.textView = controller?.textView
        overview?.changes = controller?.gutterView?.lineChanges ?? []
        if let colors { overview?.colors = colors }
    }
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
        refreshOverview()
    }

    func setBases(head: String?, index: String?) {
        bases = (head, index)
        update(after: 0)
    }

    func setColors(added: NSColor, modified: NSColor, deleted: NSColor) {
        colors = (added, modified, deleted)
        controller?.gutterView?.lineChangeColors = (added, modified, deleted)
        refreshOverview()
    }

    private func update(after delay: TimeInterval) {
        pending?.cancel()
        generation += 1
        let generation = generation
        // Reading the text copies it, so wait until typing pauses.
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, let controller = self.controller else { return }
            if let colors { controller.gutterView?.lineChangeColors = colors }
            refreshOverview()
            guard let bases else { return }
            let text = controller.textView.string
            Self.queue.async {
                let changes = EditorLineChanges.changes(text: text, head: bases.head, index: bases.index)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.controller?.gutterView?.lineChanges = changes
                    self.refreshOverview()
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

/// A separate rail leaves the native scroller usable with both overlay and legacy scrollbars.
struct EditorGitOverview: NSViewRepresentable {
    let coordinator: EditorLineChangeCoordinator

    func makeNSView(context: Context) -> EditorGitOverviewView {
        let view = EditorGitOverviewView()
        coordinator.overview = view
        return view
    }

    func updateNSView(_ view: EditorGitOverviewView, context: Context) {
        coordinator.overview = view
    }
}

/// Whole-document Git markers. Uses the line tree's current heights without forcing offscreen
/// layout; wrapped lines refine the mapping as the editor lays them out.
final class EditorGitOverviewView: NSView {
    weak var textView: TextView? {
        didSet {
            guard textView !== oldValue else { return }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            if let textView, let scrollView = textView.enclosingScrollView {
                for (name, object) in [
                    (NSView.frameDidChangeNotification, textView as NSView),
                    (NSView.boundsDidChangeNotification, scrollView.contentView as NSView),
                    (NSView.frameDidChangeNotification, scrollView.contentView as NSView)
                ] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: object,
                        queue: .main) { [weak self] _ in self?.needsDisplay = true })
                }
            }
            needsDisplay = true
        }
    }
    var changes: [GutterView.LineChange] = [] { didSet { needsDisplay = true } }
    var colors: (added: NSColor, modified: NSColor, deleted: NSColor)
        = (.systemGreen, .systemYellow, .systemRed) { didSet { needsDisplay = true } }
    private var observers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Git changes — click a marker to reveal the change"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Git changes in document")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Minimum height keeps single-line changes and deletions visible, including at EOF.
    static func markerRect(top: CGFloat, bottom: CGFloat, documentHeight: CGFloat,
                           bounds: CGRect) -> CGRect {
        guard documentHeight > 0, bounds.height > 0 else { return .zero }
        let height = min(bounds.height, max(3, (bottom - top) / documentHeight * bounds.height))
        let y = min(max(0, top / documentHeight * bounds.height), bounds.height - height)
        return CGRect(x: bounds.minX + 2, y: bounds.minY + y, width: max(0, bounds.width - 4), height: height)
    }

    func markers() -> [(change: GutterView.LineChange, rect: CGRect)] {
        guard let textView, let layout = textView.layoutManager, layout.lineCount > 0 else { return [] }
        let height = max(layout.estimatedHeight(), textView.enclosingScrollView?.contentSize.height ?? 0)
        return changes.compactMap { change in
            let firstIndex = min(max(change.line, 0), layout.lineCount - 1)
            let lastIndex = min(firstIndex + max(change.count - 1, 0), layout.lineCount - 1)
            guard let first = layout.textLineForIndex(firstIndex),
                  let last = layout.textLineForIndex(lastIndex) else { return nil }
            let top = change.line >= layout.lineCount ? last.yPos + last.height : first.yPos
            let bottom = change.kind == .deleted ? top : last.yPos + last.height
            return (change, Self.markerRect(top: top, bottom: bottom, documentHeight: height, bounds: bounds))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (change, rect) in markers() {
            let color: NSColor
            switch change.kind {
            case .added: color = colors.added
            case .modified: color = colors.modified
            case .deleted: color = colors.deleted
            }
            color.setFill()
            color.setStroke()
            if change.isStaged {
                let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            } else {
                rect.fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        revealMarker(at: convert(event.locationInWindow, from: nil))
    }

    func revealMarker(at point: CGPoint) {
        guard let textView, let scrollView = textView.enclosingScrollView,
              let marker = markers().filter({ $0.rect.insetBy(dx: -2, dy: -3).contains(point) })
                .min(by: { abs($0.rect.midY - point.y) < abs($1.rect.midY - point.y) }),
              let line = textView.layoutManager.textLineForIndex(
                min(max(marker.change.line, 0), textView.layoutManager.lineCount - 1)) else { return }
        let offset = marker.change.line >= textView.layoutManager.lineCount ? textView.length : line.range.location
        EditorScrolling.settle(on: { textView.layoutManager.rectForOffset(offset) }) { rect in
            let clip = scrollView.contentView
            let origin = CGPoint(x: clip.bounds.minX, y: rect.midY - clip.bounds.height / 2)
            clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    override func scrollWheel(with event: NSEvent) { textView?.scrollWheel(with: event) }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
