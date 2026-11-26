import AppKit
import CodeEditSourceEditor
import CodeEditTextView

/// The lines and attribution come from the same Git invocation, even if HEAD moves during a load.
struct EditorGitBlame: Sendable {
    static let storageKey = "EditorInlineGitBlame"

    let text: [String]
    let commits: [WorkspaceCommit]

    static func parse(_ data: Data) -> Self? {
        guard !data.contains(0), let output = String(data: data, encoding: .utf8) else { return nil }
        var text: [String] = []
        var commits: [WorkspaceCommit] = []
        var hash: String?
        var author: String?
        var timestamp: TimeInterval?
        var subject: String?
        var gitLine = 0

        // Split at Git's LF delimiter even where the source line itself ends in CR.
        for bytes in output.utf8.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
            let field = String(decoding: bytes, as: UTF8.self)
            if hash == nil {
                let header = field.split(separator: " ", maxSplits: 3)
                guard header.count >= 3, header[0].count == 40 || header[0].count == 64,
                      header[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      Int(header[2]) == gitLine + 1 else { return nil }
                gitLine += 1
                hash = String(header[0])
                author = nil
                timestamp = nil
                subject = nil
            } else if field.hasPrefix("\t") {
                guard let id = hash, let author, let timestamp, let subject else { return nil }
                // CodeEdit also recognizes standalone CR as a line ending.
                let source = String(field.dropFirst()) + "\n"
                let lines = Self.lines(in: source)
                let commit = WorkspaceCommit(id: id, shortHash: String(id.prefix(8)), subject: subject,
                                             author: author, date: Date(timeIntervalSince1970: timestamp))
                for line in lines {
                    text.append(String(line))
                    commits.append(commit)
                }
                hash = nil
            } else if field.hasPrefix("author ") {
                author = String(field.dropFirst("author ".count))
            } else if field.hasPrefix("author-time ") {
                timestamp = TimeInterval(field.dropFirst("author-time ".count))
            } else if field.hasPrefix("summary ") {
                subject = String(field.dropFirst("summary ".count))
            }
        }
        guard hash == nil, data.isEmpty || data.last == 10 else { return nil }
        return Self(text: text, commits: commits)
    }

    enum Line: Sendable {
        case committed(WorkspaceCommit)
        case uncommitted
    }

    func lines(matching buffer: String) -> [Line?] {
        let current = Self.lines(in: buffer)
        let edits = EditorLineChanges.lineEdits(from: text.map { $0[...] }, to: current)
        var lines = commits.prefix(edits.prefix).map { Optional(Line.committed($0)) }
        var original = edits.prefix
        for inserted in edits.inserted {
            if inserted {
                lines.append(edits.isExact ? .uncommitted : nil)
            } else {
                while edits.removed[original - edits.prefix] { original += 1 }
                lines.append(.committed(commits[original]))
                original += 1
            }
        }
        lines += commits.suffix(edits.suffix).map { .committed($0) }
        return lines
    }

    private static func lines(in text: String) -> [Substring] {
        var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

/// Renders one passive annotation inside the scrollable editor without changing text or layout.
@MainActor
final class EditorGitBlameCoordinator: @preconcurrency TextViewCoordinator {
    private weak var controller: TextViewController?
    private let annotation = Label(labelWithString: "")
    private var observers: [NSObjectProtocol] = []
    private var blame: EditorGitBlame?
    private var lines: [EditorGitBlame.Line?] = []
    private var mapping: Task<Void, Never>?
    private var refreshPending = false

    private final class Label: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        annotation.isHidden = true
        annotation.lineBreakMode = .byTruncatingTail
        annotation.setAccessibilityIdentifier("editor-git-blame")
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    private func attach() {
        guard let textView = controller?.textView, let clip = textView.enclosingScrollView?.contentView else { return }
        textView.addSubview(annotation)
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
            })
        }
        remap()
    }

    func destroy() {
        mapping?.cancel()
        lines = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        annotation.removeFromSuperview()
        controller = nil
    }

    func setBlame(_ blame: EditorGitBlame?) {
        self.blame = blame
        remap()
    }

    func setColor(_ color: NSColor) { annotation.textColor = color }

    func textViewDidChangeText(controller: TextViewController) { remap(after: .milliseconds(200)) }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) { refresh() }

    private func remap(after delay: Duration = .zero) {
        mapping?.cancel()
        lines = []
        annotation.isHidden = true
        guard let blame, controller != nil else { return }
        mapping = Task { [weak self] in
            if delay != .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled, let text = self?.controller?.textView.string else { return }
            let mapped = await Task.detached(priority: .utility) { blame.lines(matching: text) }.value
            guard !Task.isCancelled, let self else { return }
            self.lines = mapped
            self.refresh()
        }
    }

    func refresh() {
        guard !refreshPending else { return }
        refreshPending = true
        // Cursor and viewport callbacks can arrive while CodeEdit is still laying out.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.updateAnnotation()
        }
    }

    private func updateAnnotation() {
        var showAnnotation = false
        defer { annotation.isHidden = !showAnnotation }
        guard let controller, let textView = controller.textView,
              let selection = textView.selectionManager.textSelections.first,
              let row = textView.layoutManager.textLineForOffset(selection.range.location),
              lines.indices.contains(row.index), let line = lines[row.index] else { return }

        let visible = textView.visibleRect
        guard row.yPos < visible.maxY, row.yPos + row.height > visible.minY else { return }
        let fragment = row.data.lineFragments.last
        guard fragment != nil || row.range.isEmpty else { return }
        let x = textView.edgeInsets.left + (fragment?.data.width ?? 0) + 14
        let y = row.yPos + (fragment?.yPos ?? 0)
        let height = fragment?.height ?? row.height
        let width = visible.maxX - x - 8
        guard x >= visible.minX + (controller.gutterView?.frame.width ?? 0), width >= 54, y < visible.maxY, y + height > visible.minY else { return }

        switch line {
        case .committed(let commit):
            annotation.stringValue = "\(commit.author) · \(commit.relativeDate) · \(commit.subject)"
            annotation.toolTip = "\(commit.subject)\n\(commit.author) · \(commit.absoluteDate)\n\(commit.id)"
        case .uncommitted:
            annotation.stringValue = "Uncommitted changes"
            annotation.toolTip = annotation.stringValue
        }
        annotation.setAccessibilityLabel(annotation.toolTip)
        annotation.font = .systemFont(ofSize: max(9, textView.font.pointSize - 1))
        let size = annotation.intrinsicContentSize
        annotation.frame = CGRect(x: x, y: y + (height - size.height) / 2,
                                  width: min(width, size.width), height: size.height)
        showAnnotation = true
    }
}
