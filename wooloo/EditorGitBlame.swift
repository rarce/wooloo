import AppKit
import CodeEditSourceEditor
import CodeEditTextView

/// The source lines and attribution use the same pinned commit.
struct EditorGitBlame: Sendable {
    static let storageKey = "EditorInlineGitBlame"

    let text: [String]
    let commits: [WorkspaceCommit]

    static func parse(_ data: Data) -> Self? {
        guard !data.contains(0), data.last == 10, let output = String(data: data, encoding: .utf8) else { return nil }
        // Git always prints LF after a source record, even when the blob has no final LF.
        let bytes = output.utf8
        guard let headerEnd = bytes.firstIndex(of: 10) else { return nil }
        let lastByte = String(decoding: bytes[..<headerEnd], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard lastByte.isEmpty || UInt8(lastByte) != nil else { return nil }
        let endsInLF = UInt8(lastByte) == 10
        var text: [String] = []
        var commits: [WorkspaceCommit] = []
        var commitsByHash: [String: WorkspaceCommit] = [:]
        var hash: String?
        var author: String?
        var timestamp: TimeInterval?
        var subject: String?
        var gitLine = 0

        // Split at Git's LF delimiter even where the source line itself ends in CR.
        var start = bytes.index(after: headerEnd)
        while start < bytes.endIndex, let end = bytes[start...].firstIndex(of: 10) {
            let field = String(decoding: bytes[start..<end], as: UTF8.self)
            start = bytes.index(after: end)
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
                guard let id = hash else { return nil }
                let commit: WorkspaceCommit
                if let existing = commitsByHash[id] {
                    commit = existing
                } else {
                    guard let author, let timestamp, let subject else { return nil }
                    commit = WorkspaceCommit(id: id, shortHash: String(id.prefix(8)), subject: subject,
                                             author: author, date: Date(timeIntervalSince1970: timestamp))
                    commitsByHash[id] = commit
                }
                let needsLF = start != bytes.endIndex || endsInLF
                let source = String(field.dropFirst()) + (needsLF ? "\n" : "")
                let lines = Self.editorLines(in: source)
                for line in lines {
                    text.append(line)
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
        guard hash == nil else { return nil }
        return Self(text: text, commits: commits)
    }

    enum Line: Sendable {
        case committed(WorkspaceCommit)
        case uncommitted
    }

    func lines(matching buffer: String) -> [Line?] {
        let current = Self.editorLines(in: buffer)
        let edits = EditorLineChanges.lineEdits(from: text.map { $0[...] }, to: current.map { $0[...] })
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

    /// CodeEdit uses NSString's line boundaries, including Unicode line and paragraph separators.
    /// Keep each terminator in the diff so adding or removing the final newline changes that row.
    private static func editorLines(in text: String) -> [String] {
        let source = text as NSString
        var lines: [String] = []
        var start = 0
        while start < source.length {
            var end = 0
            source.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: start, length: 0))
            lines.append(source.substring(with: NSRange(location: start, length: end - start)))
            start = end
        }
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
