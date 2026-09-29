import SwiftUI

struct HerdrSettingsView: View {
    let socketPath: String
    let sessionName: String
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var category: Category = .terminal
    @State private var document = HerdrConfigDocument(text: "")
    @State private var original = ""
    @State private var message: String?
    @State private var isSaving = false

    private enum Category: String, CaseIterable, Identifiable {
        case terminal = "Terminal"
        case shortcuts = "Shortcuts"
        case worktrees = "Worktrees"
        case appearance = "Appearance"
        case server = "Server"
        case advanced = "Advanced TOML"

        var id: Self { self }
        var icon: String {
            switch self {
            case .terminal: "terminal"
            case .shortcuts: "keyboard"
            case .worktrees: "point.topleft.down.curvedto.point.bottomright.up"
            case .appearance: "paintpalette"
            case .server: "server.rack"
            case .advanced: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    init(socketPath: String, sessionName: String, showShortcuts: Bool = false,
         onSaved: @escaping () -> Void = {}) {
        self.socketPath = socketPath
        self.sessionName = sessionName
        self.onSaved = onSaved
        _category = State(initialValue: showShortcuts ? .shortcuts : .terminal)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HERDR SETTINGS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                ForEach(Category.allCases) { item in
                    Button {
                        category = item
                        message = nil
                    } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(category == item ? Color.white.opacity(0.09) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 170)
            .background(Color(red: 0.105, green: 0.115, blue: 0.13))

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(category.rawValue)
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderless)
                        .disabled(isSaving)
                }
                .padding(.horizontal, 20)
                .frame(height: 48)
                Divider()

                Group {
                    if category == .advanced {
                        advancedEditor
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 19) {
                                Text("Local config.toml · shared by all Herdr sessions. Reload applies to \(sessionName).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                categoryFields
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                HStack(spacing: 10) {
                    if let message {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(message.hasPrefix("Saved") ? .green : .orange)
                            .lineLimit(2)
                    } else {
                        Text(document.text == original ? "No changes" : "Unsaved changes")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(document.text == original ? "Reload file" : "Discard & reload") { load() }
                        .disabled(isSaving)
                    Button("Save & reload Herdr") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || document.text == original)
                }
                .padding(.horizontal, 20)
                .frame(height: 54)
            }
        }
        .frame(width: 800, height: 540)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var categoryFields: some View {
        switch category {
        case .terminal:
            description("Defaults for new panes. Existing shells keep running with their current settings.")
            field("Default shell", hint: "Executable name or path; blank uses $SHELL") {
                TextField("Use $SHELL", text: string("terminal", "default_shell", default: ""))
                    .textFieldStyle(.roundedBorder)
            }
            field("Shell startup", hint: "Auto starts login shells on macOS") {
                Picker("", selection: string("terminal", "shell_mode", default: "auto")) {
                    Text("Auto").tag("auto")
                    Text("Login").tag("login")
                    Text("Non-login").tag("non_login")
                }
                .labelsHidden()
                .frame(width: 220)
            }
            field("New pane directory", hint: "Follow, home, current, or an explicit path") {
                TextField("follow", text: string("terminal", "new_cwd", default: "follow"))
                    .textFieldStyle(.roundedBorder)
            }
        case .shortcuts:
            description("Press the prefix, release it, then press the action key. These bindings follow Herdr's [keys] format and apply in the xherdr terminal. Separate alternatives with commas.")
            field("Prefix", hint: "Default: ctrl+b. One direct chord, such as ctrl+a.") {
                TextField("ctrl+b", text: string("keys", "prefix", default: "ctrl+b"))
                    .textFieldStyle(.roundedBorder)
            }
            ForEach(HerdrShortcutDefinition.supported) { definition in
                field(definition.title, hint: "Default: \(definition.defaultBindings.joined(separator: ", "))") {
                    TextField(definition.defaultBindings.joined(separator: ", "),
                              text: shortcutBindings(definition))
                        .textFieldStyle(.roundedBorder)
                }
            }
        case .worktrees:
            description("Where Herdr creates Git worktree checkouts from the sidebar.")
            field("Worktree directory", hint: "A path such as ~/Projects/herdr-worktrees") {
                TextField("~/.herdr/worktrees", text: string("worktrees", "directory", default: "~/.herdr/worktrees"))
                    .textFieldStyle(.roundedBorder)
            }
        case .appearance:
            description("Herdr's own terminal theme. xherdr currently uses its native macOS colors.")
            field("Theme", hint: "Built-in Herdr theme name") {
                TextField("catppuccin", text: string("theme", "name", default: "catppuccin"))
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Follow host light/dark appearance", isOn: bool("theme", "auto_switch", default: false))
            field("Light theme", hint: "Optional theme when auto switching") {
                TextField("Built-in matching theme", text: string("theme", "light_name", default: ""))
                    .textFieldStyle(.roundedBorder)
            }
            field("Dark theme", hint: "Optional theme when auto switching") {
                TextField("Built-in matching theme", text: string("theme", "dark_name", default: ""))
                    .textFieldStyle(.roundedBorder)
            }
        case .server:
            description("Headless size applies when no client is attached. These values must be positive.")
            field("Headless columns", hint: "Default: 120") {
                TextField("120", value: integer("server", "headless_cols", default: 120), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            field("Headless rows", hint: "Default: 40") {
                TextField("40", value: integer("server", "headless_rows", default: 40), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
        case .advanced:
            EmptyView()
        }
    }

    private var advancedEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full local config.toml. Other Herdr settings and comments stay here when guided fields change.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(HerdrConfigFile.url.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            TextEditor(text: $document.text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(5)
                .background(Color.black.opacity(0.23), in: RoundedRectangle(cornerRadius: 5))
            Link("Herdr configuration reference", destination: URL(string: "https://herdr.dev/docs/config-reference/")!)
                .font(.system(size: 11))
        }
        .padding(20)
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field<Content: View>(_ title: String, hint: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            content()
            Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func string(_ section: String, _ key: String, default fallback: String) -> Binding<String> {
        Binding(get: { document.string(section: section, key: key, default: fallback) },
                set: {
                    guard $0 != document.string(section: section, key: key, default: fallback) else { return }
                    document.setString($0, section: section, key: key)
                })
    }

    private func bool(_ section: String, _ key: String, default fallback: Bool) -> Binding<Bool> {
        Binding(get: { document.bool(section: section, key: key, default: fallback) },
                set: {
                    guard $0 != document.bool(section: section, key: key, default: fallback) else { return }
                    document.setBool($0, section: section, key: key)
                })
    }

    private func integer(_ section: String, _ key: String, default fallback: Int) -> Binding<Int> {
        Binding(get: { document.integer(section: section, key: key, default: fallback) },
                set: {
                    guard $0 != document.integer(section: section, key: key, default: fallback) else { return }
                    document.setInteger($0, section: section, key: key)
                })
    }

    private func shortcutBindings(_ definition: HerdrShortcutDefinition) -> Binding<String> {
        Binding(get: {
            document.bindings(definition.key, default: definition.defaultBindings).joined(separator: ", ")
        }, set: { value in
            let current = document.bindings(definition.key, default: definition.defaultBindings)
                .joined(separator: ", ")
            guard value != current else { return }
            let values = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            document.setBindings(values, key: definition.key)
        })
    }

    private func load() {
        do {
            original = try HerdrConfigFile.read(at: HerdrConfigFile.url)
            document = HerdrConfigDocument(text: original)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func save() {
        let text = document.text
        let old = original
        let url = HerdrConfigFile.url
        let path = socketPath
        let session = sessionName
        isSaving = true
        message = "Validating with Herdr…"
        Task.detached(priority: .userInitiated) {
            do {
                try HerdrConfigFile.save(text, original: old, at: url)
                let result: String
                do {
                    result = try HerdrConfigFile.reloadServer(socketPath: path)
                } catch {
                    result = "Saved config.toml, but \(session) could not reload: \(error.localizedDescription)"
                }
                await MainActor.run {
                    original = text
                    message = result
                    isSaving = false
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    message = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}
