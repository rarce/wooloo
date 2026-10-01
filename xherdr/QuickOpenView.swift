import AppKit
import SwiftUI

/// Go to File over the whole window while it is open; a click outside the panel closes it.
struct QuickOpenOverlay: View {
    @ObservedObject var model: QuickOpenModel
    let onOpen: () -> Void

    var body: some View {
        if model.isPresented {
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismiss() }
                QuickOpenPanel(model: model, onOpen: onOpen)
                    .padding(.top, 44)
                    .padding(.horizontal, 16)
            }
        }
    }
}

private struct QuickOpenPanel: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    @ObservedObject var model: QuickOpenModel
    let onOpen: () -> Void

    private var rowHeight: CGFloat { typography.metric(26) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: typography.emphasis))
                    .foregroundStyle(theme.accent)
                PickerField(text: $model.query, placeholder: "Go to file…", font: .systemFont(ofSize: typography.emphasis),
                            onMove: { model.move($0) }, onSubmit: onOpen, onCancel: { model.dismiss() })
                if model.isIndexing { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 11)
            .frame(height: typography.metric(36))
            Divider()
            if model.results.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: typography.body))
                    .foregroundStyle(model.error == nil ? Color.secondary : theme.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                results
            }
            Divider()
            footer
        }
        .pickerPanel(theme)
    }

    private var emptyMessage: String {
        if let error = model.error { return error }
        if model.isIndexing { return "Reading files…" }
        if QuickOpenQuery(model.query).terms.isEmpty {
            return "Type part of a file name or path. Add :line to go to a line."
        }
        return "No matching files"
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.path) { index, match in
                        row(match, selected: index == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = index
                                onOpen()
                            }
                    }
                }
                .padding(4)
            }
            .frame(height: min(CGFloat(model.results.count) * rowHeight + 8, 380))
            // Rows are identified by their path; an index would let reused rows keep old contents.
            .onChange(of: model.selection) { _, _ in
                if let match = model.selectedMatch { proxy.scrollTo(match.path) }
            }
        }
    }

    private func row(_ match: QuickOpenMatch, selected: Bool) -> some View {
        let name = (match.path as NSString).lastPathComponent
        let nameOffset = match.path.utf8.count - name.utf8.count
        let folder = nameOffset > 0 ? String(match.path.utf8.prefix(nameOffset - 1)) ?? "" : ""
        return HStack(spacing: 7) {
            Image(systemName: WorkspaceExplorer.fileIcon(match.path))
                .font(.system(size: typography.secondary))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(highlighted(name, from: nameOffset, match.positions))
                .font(.system(size: typography.body))
                .lineLimit(1)
                .layoutPriority(1)
            Text(highlighted(folder, from: 0, match.positions))
                .font(.system(size: typography.secondary))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if match.isRecent {
                Image(systemName: "clock")
                    .font(.system(size: typography.caption))
                    .foregroundStyle(.tertiary)
                    .help("Opened recently")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(selected ? theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private func highlighted(_ text: String, from offset: Int, _ positions: [Int]) -> AttributedString {
        PickerHighlight.text(text, from: offset, positions, color: theme.accent, size: typography.body)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let location = model.location {
                Label("\(location.machineLabel) · \(location.workspaceLabel)",
                      systemImage: location.isLocal ? "desktopcomputer" : "network")
                    .lineLimit(1)
                    .help(location.root)
            }
            if model.isTruncated {
                Text("· first \(WorkspaceFiles.maximumFiles.formatted()) files only")
                    .foregroundStyle(theme.warning)
            }
            Spacer(minLength: 8)
            Text("↑↓ select  ↩ open  esc close")
        }
        .font(.system(size: typography.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11)
        .frame(height: typography.metric(24))
    }
}

/// Matched characters in a picker row.
enum PickerHighlight {
    /// `text` with the matched characters emphasized; it starts `offset` UTF-8 bytes into the
    /// string `positions` index.
    static func text(_ text: String, from offset: Int, _ positions: [Int], color: Color, size: CGFloat) -> AttributedString {
        let matched = Set(positions)
        var result = AttributedString()
        var byte = offset
        for character in text {
            var part = AttributedString(String(character))
            let length = character.utf8.count
            if (byte..<byte + length).contains(where: matched.contains) {
                part.foregroundColor = color
                part.font = .system(size: size, weight: .bold)
            }
            result += part
            byte += length
        }
        return result
    }
}

extension View {
    /// The floating panel of Go to File and the command palette.
    func pickerPanel(_ theme: XherdrTheme) -> some View {
        frame(maxWidth: 620)
            .background(theme.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
    }
}

/// A picker's query field. An AppKit field, so ↑, ↓, ⌃N, ⌃P, ↩ and Esc reach the list instead of
/// moving the caret.
struct PickerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.font != font { field.font = font }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PickerField

        init(_ parent: PickerField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
