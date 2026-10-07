import SwiftUI

/// The command palette over the whole window while it is open; a click outside the panel closes it.
struct CommandPaletteOverlay: View {
    @ObservedObject var model: CommandPaletteModel
    let onRun: () -> Void

    var body: some View {
        if model.isPresented {
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismiss() }
                CommandPalettePanel(model: model, onRun: onRun)
                    .padding(.top, 44)
                    .padding(.horizontal, 16)
            }
        }
    }
}

private struct CommandPalettePanel: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    @ObservedObject var model: CommandPaletteModel
    let onRun: () -> Void

    private var rowHeight: CGFloat { typography.metric(26) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: typography.emphasis))
                    .foregroundStyle(theme.accent)
                PickerField(text: $model.query, placeholder: "Run a command…",
                            font: .systemFont(ofSize: typography.emphasis),
                            onMove: { model.move($0) }, onSubmit: onRun, onCancel: { model.dismiss() })
            }
            .padding(.horizontal, 11)
            .frame(height: typography.metric(36))
            Divider()
            if model.results.isEmpty {
                Text("No matching commands")
                    .font(.system(size: typography.body))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                results
            }
        }
        .pickerPanel(theme)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.item.action) { index, match in
                        row(match, selected: index == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = index
                                onRun()
                            }
                    }
                }
                .padding(4)
            }
            .frame(height: min(CGFloat(model.results.count) * rowHeight + 8, 380))
            // Rows are identified by their command; an index would let reused rows keep old contents.
            .onChange(of: model.selection) { _, _ in
                if let match = model.selectedMatch { proxy.scrollTo(match.item.action) }
            }
        }
    }

    private func row(_ match: CommandPaletteMatch, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(PickerHighlight.text(match.item.label, from: 0, match.positions, color: theme.accent, size: typography.body))
                .font(.system(size: typography.body))
                .lineLimit(1)
            if match.isRecent {
                Text("recent")
                    .font(.system(size: typography.caption))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let binding = match.binding {
                keys(binding).help("Herdr binding")
            }
            if let shortcut = match.item.shortcutLabel {
                keys(shortcut)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(selected ? theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private func keys(_ label: String) -> some View {
        Text(label)
            .font(.system(size: typography.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: typography.metric(17))
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
    }
}
