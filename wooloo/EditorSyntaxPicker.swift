import SwiftUI

struct EditorSyntaxPicker: View {
    let detected: EditorSyntax
    let path: String
    @Binding var selection: String?
    @Binding var associationsJSON: String
    @State private var isPresented = false
    @State private var query = ""
    @State private var editsAssociations = false
    @State private var pattern = ""
    @State private var associationSyntax = "properties"

    private var selected: EditorSyntax? { EditorSyntax.named(selection) }
    private var associations: [SyntaxAssociation] { SyntaxAssociation.decode(associationsJSON) }
    private var choices: [EditorSyntax] {
        EditorSyntax.all.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Button {
            query = ""
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(selected?.name ?? "Auto: \(detected.name)")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .help("Select the file's syntax or configure file associations")
        .accessibilityIdentifier("editor-syntax-picker")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Syntax").font(.headline)
                TextField("Search languages", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button {
                    selection = nil
                    isPresented = false
                } label: {
                    Label("Auto: \(detected.name)", systemImage: selected == nil ? "checkmark" : "wand.and.stars")
                }
                .buttonStyle(.plain)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(choices) { syntax in
                            Button {
                                selection = syntax.id
                                isPresented = false
                            } label: {
                                HStack {
                                    Text(syntax.name)
                                    Spacer()
                                    if selected == syntax { Image(systemName: "checkmark") }
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 220)
                if choices.isEmpty { Text("No matching languages").foregroundStyle(.secondary) }
                Divider()
                Button("File Associations…") {
                    let ext = (path as NSString).pathExtension
                    pattern = ext.isEmpty ? (path as NSString).lastPathComponent : "*.\(ext)"
                    associationSyntax = selected?.id ?? detected.id
                    isPresented = false
                    editsAssociations = true
                }
            }
            .padding(14)
            .frame(width: 290)
        }
        .sheet(isPresented: $editsAssociations) {
            VStack(alignment: .leading, spacing: 14) {
                Text("File Associations").font(.headline)
                Text(verbatim: "Apply syntax automatically across workspaces. Use a filename or pattern: *.conf, nginx.conf, or config/**/*.conf.")
                    .foregroundStyle(.secondary)
                TextField("Filename or pattern", text: $pattern)
                Picker("Syntax", selection: $associationSyntax) {
                    ForEach(EditorSyntax.all) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Spacer()
                    Button("Save Association") {
                        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                        var values = associations.filter { $0.pattern != trimmed }
                        values.append(SyntaxAssociation(pattern: trimmed, syntaxID: associationSyntax))
                        associationsJSON = SyntaxAssociation.encode(values)
                        selection = nil
                        pattern = ""
                    }
                    .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Divider()
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(associations) { rule in
                            HStack {
                                Text(rule.pattern).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(EditorSyntax.named(rule.syntaxID)?.name ?? rule.syntaxID).foregroundStyle(.secondary)
                                Button {
                                    associationsJSON = SyntaxAssociation.encode(associations.filter { $0.id != rule.id })
                                } label: { Image(systemName: "trash") }
                                .help("Remove association for \(rule.pattern)")
                            }
                        }
                        if associations.isEmpty { Text("No custom associations").foregroundStyle(.secondary) }
                    }
                }
                .frame(height: 150)
                HStack {
                    Text("Specific patterns take priority. Manual syntax choices override associations.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { editsAssociations = false }.keyboardShortcut(.defaultAction)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(20)
            .frame(width: 500)
        }
    }
}
