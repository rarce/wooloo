import SwiftUI

enum WorkspaceDocumentKind: String {
    case file
    case change

    var icon: String { self == .file ? "doc.text" : "arrow.left.arrow.right" }
}

struct WorkspaceDocument: Identifiable {
    let location: WorkspaceFileLocation
    let path: String
    let kind: WorkspaceDocumentKind
    var text = ""
    var savedText = ""
    var version: String?
    var isLoading = true
    var isSaving = false
    var error: String?

    var id: String { "\(location.identity)|\(kind.rawValue)|\(path)" }
    var isDirty: Bool { kind == .file && text != savedText }
    var title: String { (path as NSString).lastPathComponent }
}

struct WorkspaceDocumentView: View {
    @Binding var document: WorkspaceDocument
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: document.kind.icon)
                    .foregroundStyle(.cyan)
                Text(document.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(document.location.machineLabel) · \(document.location.workspaceLabel)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                if document.kind == .file {
                    Button("Save") { onSave() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(document.isLoading || document.isSaving || !document.isDirty)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .frame(height: 33)
            Divider()

            if document.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = document.error, document.version == nil {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if document.kind == .file {
                VStack(spacing: 0) {
                    if let error = document.error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    TextEditor(text: $document.text)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(7)
                }
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(document.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                            Text(String(line).isEmpty ? " " : String(line))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(diffColor(String(line)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 1)
                                .background(diffBackground(String(line)))
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Text(document.kind == .file ? (document.isDirty ? "Unsaved changes" : "UTF-8 text") : "Git diff")
                Spacer()
                if document.isSaving { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .frame(height: 23)
        }
        .background(Color(red: 0.075, green: 0.082, blue: 0.091))
    }

    private func diffColor(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") { return .cyan }
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }

    private func diffBackground(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green.opacity(0.08) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red.opacity(0.08) }
        if line.hasPrefix("@@") { return .blue.opacity(0.08) }
        return .clear
    }
}
