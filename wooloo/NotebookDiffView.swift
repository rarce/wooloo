import SwiftUI

/// Whether a notebook's diff shows its cells (`NotebookDiff`) or the JSON patch.
enum NotebookDiffMode: String, CaseIterable, Identifiable {
    case cells = "Cells"
    case json = "JSON"

    static let storageKey = "NotebookDiffMode"

    var id: Self { self }
}

/// A notebook's changes cell by cell: each changed cell with what changed, its source as a line
/// diff and a summary of its outputs when they changed, and runs of unchanged cells folded.
/// Falls back to the JSON patch (`fallback`) when either side is not a notebook it can read.
struct NotebookDiffView<Fallback: View>: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    let text: String
    let source: DiffSource
    /// Called with whether the JSON patch is shown instead of the cells.
    var onFallback: (Bool) -> Void = { _ in }
    @ViewBuilder let fallback: () -> Fallback
    @State private var diff: NotebookDiff?
    @State private var loadedSource: DiffSource?
    @State private var loadedText: String?
    @State private var failed = false
    @State private var expanded: Set<Int> = []

    var body: some View {
        Group {
            if failed, loadedSource == source, loadedText == text {
                fallback()
            } else if let diff, loadedSource == source, loadedText == text {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        summary(diff)
                        ForEach(groups(diff), id: \.first!.id) { group in
                            if group.count > 1 || group[0].status == .unchanged && !expanded.contains(group[0].id) {
                                folded(group)
                            } else {
                                card(group[0])
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(source.path)|\(source.commit ?? "")|\(source.scope)|\(text.hashValue)") {
            let key = (source, text)
            let result = await WorkspaceFiles.blocking(at: key.0.location, priority: .userInitiated) { () -> NotebookDiff? in
                if let snapshots = key.0.snapshots {
                    return NotebookDiff.compare(old: snapshots.old, new: snapshots.new)
                }
                let sides = WorkspaceFiles.diffSides(key.0.path, originalPath: key.0.originalPath, commit: key.0.commit,
                                                     scope: key.0.scope, at: key.0.location)
                return NotebookDiff.compare(old: sides.old, new: sides.new, patch: key.1)
            }
            guard !Task.isCancelled else { return }
            diff = result
            failed = diff == nil
            onFallback(failed)
            expanded = []
            loadedSource = key.0
            loadedText = key.1
        }
    }

    /// Changed cells one by one, and each run of unchanged cells together.
    private func groups(_ diff: NotebookDiff) -> [[NotebookDiff.Cell]] {
        var result: [[NotebookDiff.Cell]] = []
        for cell in diff.cells {
            if cell.status == .unchanged, !expanded.contains(cell.id), let last = result.last,
               last[0].status == .unchanged, !expanded.contains(last[0].id) {
                result[result.count - 1].append(cell)
            } else {
                result.append([cell])
            }
        }
        return result
    }

    private func summary(_ diff: NotebookDiff) -> some View {
        let added = diff.cells.filter { $0.status == .added }.count
        let removed = diff.cells.filter { $0.status == .removed }.count
        let modified = diff.cells.filter { $0.status == .modified }.count
        var parts = ["\(modified) modified", "\(added) added", "\(removed) removed"]
        if diff.metadataChanged { parts.append("notebook metadata changed") }
        return Text(diff.changedCount == 0 && !diff.metadataChanged ? "No cell changes" : parts.joined(separator: " · "))
            .font(.system(size: typography.body))
            .foregroundStyle(.secondary)
    }

    private func folded(_ group: [NotebookDiff.Cell]) -> some View {
        Button {
            group.forEach { expanded.insert($0.id) }
        } label: {
            Label(group.count == 1 ? "1 unchanged cell" : "\(group.count) unchanged cells",
                  systemImage: "chevron.down")
                .font(.system(size: typography.body))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .help("Show the unchanged cells")
    }

    private func card(_ cell: NotebookDiff.Cell) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(status(cell))
                    .foregroundStyle(color(cell.status))
                Text(position(cell))
                Text(cell.kind).foregroundStyle(.secondary)
                if !cell.aspects.isEmpty {
                    Text(cell.aspects.map(\.rawValue).joined(separator: ", ")).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.system(size: typography.body))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            lines(cell.source)
            if !cell.outputs.isEmpty {
                Divider()
                Text("Outputs")
                    .font(.system(size: typography.body))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                lines(cell.outputs)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.contentBackground))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color(cell.status).opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status(cell)) \(position(cell))")
    }

    private func lines(_ lines: [NotebookDiff.Line]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty {
                Text("Empty").foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 2)
            }
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                HStack(alignment: .top, spacing: 6) {
                    Text(line.kind == .added ? "+" : line.kind == .removed ? "-" : " ")
                        .foregroundStyle(color(line.kind))
                    Text(line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(line.kind == .context ? Color.primary : color(line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .background(background(line.kind))
            }
        }
        .font(typography.swiftUICodeFont)
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    private func status(_ cell: NotebookDiff.Cell) -> String {
        switch cell.status {
        case .unchanged: "Unchanged"
        case .added: "Added"
        case .removed: "Removed"
        case .modified: "Modified"
        }
    }

    private func position(_ cell: NotebookDiff.Cell) -> String {
        switch (cell.oldIndex, cell.newIndex) {
        case (let old?, let new?) where old != new: "Cell \(old + 1) → \(new + 1)"
        case (_, let new?): "Cell \(new + 1)"
        case (let old?, nil): "Cell \(old + 1)"
        default: "Cell"
        }
    }

    private func color(_ status: NotebookDiff.Status) -> Color {
        switch status {
        case .added: theme.diffAdded
        case .removed: theme.diffRemoved
        case .modified: theme.accent
        case .unchanged: .secondary
        }
    }

    private func color(_ kind: NotebookDiff.Line.Kind) -> Color {
        switch kind {
        case .added: theme.diffAdded
        case .removed: theme.diffRemoved
        case .context: .secondary
        }
    }

    private func background(_ kind: NotebookDiff.Line.Kind) -> Color {
        switch kind {
        case .added: theme.diffAdded.opacity(0.12)
        case .removed: theme.diffRemoved.opacity(0.12)
        case .context: .clear
        }
    }
}
