import SwiftUI

/// Project search state; lives in ContentView so the Search tab keeps its results while hidden.
@MainActor
final class WorkspaceSearchModel: ObservableObject {
    static let tabID = "project-search"

    @Published var options = WorkspaceSearchOptions()
    @Published var replacement = ""
    @Published var showsReplace = false
    @Published var showsFilters = false
    @Published var activeMatch = 0
    @Published private(set) var result: WorkspaceSearchResult?
    @Published private(set) var matches: [WorkspaceSearchMatchRef] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isReplacing = false
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    @Published private(set) var focusRequest = 0
    @Published private(set) var location: WorkspaceFileLocation?

    /// True when a file has unsaved edits in an open document; replace skips those files.
    var hasUnsavedEdits: (WorkspaceFileLocation, String) -> Bool = { _, _ in false }
    /// Called with files written by a replace so open documents can reload.
    var didModifyFiles: (WorkspaceFileLocation, [String]) -> Void = { _, _ in }

    private var generation = 0

    var title: String { options.query.isEmpty ? "Project Search" : options.query }

    func requestFocus() { focusRequest += 1 }

    func setLocation(_ location: WorkspaceFileLocation?) {
        guard location?.identity != self.location?.identity else { return }
        self.location = location
        search(debounce: false)
    }

    func search(debounce: Bool) {
        generation += 1
        let current = generation
        status = nil
        guard let location, !options.isEmpty else {
            result = nil
            matches = []
            error = nil
            isSearching = false
            return
        }
        do { _ = try WorkspaceSearch.expression(for: options) } catch {
            self.error = error.localizedDescription
            result = nil
            matches = []
            isSearching = false
            return
        }
        isSearching = true
        let options = options
        Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard current == generation else { return }
            }
            let outcome = await BlockingWork.run(priority: .userInitiated) {
                Result { try WorkspaceSearch.search(options, at: location) }
            }
            guard current == generation else { return }
            isSearching = false
            switch outcome {
            case .success(let value):
                result = value
                error = nil
                matches = value.files.flatMap { file in
                    file.excerpts.joined().flatMap { line in
                        line.matches.indices.map { WorkspaceSearchMatchRef(path: file.path, line: line.number, occurrence: $0) }
                    }
                }
                activeMatch = matches.isEmpty ? 0 : min(activeMatch, matches.count - 1)
            case .failure(let failure):
                result = nil
                matches = []
                error = failure.localizedDescription
            }
        }
    }

    func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        activeMatch = (activeMatch + delta + matches.count) % matches.count
    }

    func replaceNext() {
        guard let location, matches.indices.contains(activeMatch), !isReplacing else { return }
        let target = matches[activeMatch]
        guard !hasUnsavedEdits(location, target.path) else {
            status = "\(target.path) has unsaved edits; save or close it first"
            return
        }
        runReplace(location: location, paths: [target.path], target: target)
    }

    func replaceAll() {
        guard let location, let result, !isReplacing else { return }
        runReplace(location: location, paths: result.files.map(\.path), target: nil)
    }

    private func runReplace(location: WorkspaceFileLocation, paths: [String], target: WorkspaceSearchMatchRef?) {
        let options = options
        let replacement = replacement
        let skipped = paths.filter { hasUnsavedEdits(location, $0) }
        let writable = paths.filter { !skipped.contains($0) }
        isReplacing = true
        Task {
            guard let outcome = try? await BlockingWork.run(priority: .userInitiated, { () -> (count: Int, files: [String], failures: [String]) in
                var count = 0
                var files: [String] = []
                var failures: [String] = []
                for path in writable {
                    do {
                        let replaced = try WorkspaceSearch.replace(in: path, options: options, replacement: replacement,
                                                                   only: target, at: location)
                        if replaced > 0 { count += replaced; files.append(path) }
                    } catch {
                        failures.append("\(path): \(error.localizedDescription)")
                    }
                }
                return (count, files, failures)
            }) else {
                isReplacing = false
                return
            }
            isReplacing = false
            var parts = ["Replaced \(outcome.count) match\(outcome.count == 1 ? "" : "es") in \(outcome.files.count) file\(outcome.files.count == 1 ? "" : "s")"]
            if !skipped.isEmpty { parts.append("skipped \(skipped.count) with unsaved edits") }
            if !outcome.failures.isEmpty { parts.append("failed: " + outcome.failures.joined(separator: "; ")) }
            if !outcome.files.isEmpty { didModifyFiles(location, outcome.files) }
            search(debounce: false)
            status = parts.joined(separator: " · ")
        }
    }
}

struct WorkspaceSearchView: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    @ObservedObject var model: WorkspaceSearchModel
    let onOpen: (WorkspaceFileLocation, String, Int, NSRange?) -> Void

    @FocusState private var focusedField: Field?
    @State private var confirmsReplaceAll = false

    private enum Field { case query, replace, include, exclude }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            results
        }
        .background(theme.contentBackground)
        .background {
            Button("Open Match") { openActive() }
                .keyboardShortcut(.return, modifiers: .option)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .onAppear { focusedField = .query }
        .onChange(of: model.focusRequest) { _, _ in focusedField = .query }
        .onChange(of: model.options) { _, _ in model.search(debounce: true) }
        .confirmationDialog("Replace all matches?", isPresented: $confirmsReplaceAll) {
            Button("Replace All", role: .destructive) { model.replaceAll() }
        } message: {
            let files = model.result?.files.count ?? 0
            Text("\(model.matches.count) matches in \(files) files will be replaced and saved to disk. This cannot be undone from wooloo.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.showsReplace ? "text.magnifyingglass" : "magnifyingglass")
                .font(.system(size: typography.title, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.showsReplace ? "Project Search & Replace" : "Project Search")
                    .font(.system(size: typography.emphasis, weight: .semibold))
                Text(model.showsReplace
                     ? "Find text in every file of the Space and replace matches; replaced files are saved to disk."
                     : "Find text in every file of the Space, including remote Spaces over SSH.")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let location = model.location {
                Label("\(location.machineLabel) · \(location.workspaceLabel)",
                      systemImage: location.isLocal ? "desktopcomputer" : "network")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(location.root)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: typography.metric(44))
    }

    // MARK: - Search bar

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                field("Search all files…", text: $model.options.query, focus: .query)
                    .onSubmit { model.search(debounce: false) }
                toggle("Aa", help: "Match Case (⌥⌘C)", isOn: $model.options.caseSensitive)
                    .keyboardShortcut("c", modifiers: [.command, .option])
                toggle("ab", help: "Match Whole Word (⌥⌘W)", isOn: $model.options.wholeWord, underline: true)
                    .keyboardShortcut("w", modifiers: [.command, .option])
                toggle(".*", help: "Use Regular Expression (⌥⌘X)", isOn: $model.options.regex)
                    .keyboardShortcut("x", modifiers: [.command, .option])
                counter
                iconButton("chevron.up", help: "Previous Match (⇧⌘G)") { model.move(-1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.matches.isEmpty)
                iconButton("chevron.down", help: "Next Match (⌘G)") { model.move(1) }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(model.matches.isEmpty)
                labeledButton("Replace", symbol: "arrow.left.arrow.right",
                              help: "Show or hide the replace field (⇧⌘H)", active: model.showsReplace) {
                    model.showsReplace.toggle()
                    if model.showsReplace { focusedField = .replace }
                }
                labeledButton("Filters", symbol: "line.3.horizontal.decrease",
                              help: "Show or hide include/exclude filters (⇧⌘J)", active: model.showsFilters) {
                    model.showsFilters.toggle()
                    if model.showsFilters { focusedField = .include }
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            }
            if model.showsReplace {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: typography.body))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                        .help("Replace with")
                    field(model.options.regex ? "Replace with… ($1 inserts a capture group)" : "Replace with…",
                          text: $model.replacement, focus: .replace)
                        .onSubmit { model.replaceNext() }
                    Button("Replace Next", systemImage: "arrow.right.to.line") { model.replaceNext() }
                        .disabled(model.matches.isEmpty || model.isReplacing)
                        .help("Replace the active match and save (↩ in the replace field)")
                    Button("Replace All", systemImage: "arrow.right.to.line.compact") { confirmsReplaceAll = true }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.matches.isEmpty || model.isReplacing)
                        .help("Replace every match and save (⌘↩)")
                    if model.isReplacing { ProgressView().controlSize(.small) }
                }
                .controlSize(.small)
            }
            if model.showsFilters {
                HStack(spacing: 6) {
                    field("Include: e.g. src/**/*.swift", text: $model.options.include, focus: .include)
                    field("Exclude: e.g. Vendor/**, *.lock", text: $model.options.exclude, focus: .exclude)
                    Toggle("Ignored files", isOn: $model.options.includeIgnored)
                        .toggleStyle(.checkbox)
                        .font(.system(size: typography.body))
                        .help("Also search files ignored by .gitignore")
                }
            }
            if let error = model.error {
                Text(error).font(.system(size: typography.body)).foregroundStyle(theme.error)
            } else if let status = model.status {
                Text(status).font(.system(size: typography.body)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func field(_ prompt: String, text: Binding<String>, focus: Field) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: typography.code, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: typography.metric(26))
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(focus == .query && model.error != nil ? theme.error.opacity(0.7)
                        : (focusedField == focus ? theme.accent.opacity(0.5) : Color.clear)))
            .focused($focusedField, equals: focus)
    }

    private func toggle(_ label: String, help: String, isOn: Binding<Bool>, underline: Bool = false) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(label)
                .font(.system(size: typography.body, weight: .semibold, design: .monospaced))
                .underline(underline)
                .frame(width: 26, height: typography.metric(22))
                .background(isOn.wrappedValue ? theme.accent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(isOn.wrappedValue ? theme.accent : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: typography.body))
                .frame(width: 24, height: typography.metric(22))
                .background(active ? theme.accent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(active ? theme.accent : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func labeledButton(_ title: String, symbol: String, help: String, active: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: typography.secondary, weight: active ? .semibold : .regular))
                .padding(.horizontal, 7)
                .frame(height: typography.metric(22))
                .background(active ? theme.accent.opacity(0.25) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(active ? theme.accent : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var counter: some View {
        let total = model.matches.count
        let suffix = model.result?.truncated == true ? "+" : ""
        return HStack(spacing: 3) {
            if model.isSearching { ProgressView().controlSize(.mini) }
            if model.result?.truncated == true {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.warning)
                    .help("Search limits reached. Try narrowing your search.")
            }
            Text(total == 0 ? "0/0" : "\(model.activeMatch + 1)/\(total)\(suffix)")
                .foregroundStyle(total == 0 && !model.options.isEmpty && !model.isSearching ? theme.error : Color.secondary)
        }
        .font(.system(size: typography.body, design: .monospaced))
        .frame(minWidth: 64, alignment: .trailing)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if model.options.isEmpty {
            emptyState("Search All Files",
                       detail: (model.location.map { "Searching \($0.root) on \($0.machineLabel)." } ?? "Select a Space in the Files sidebar.")
                           + "\nFiles ignored by .gitignore and binary files are skipped."
                           + "\nUse Replace to change every match, or Filters to limit which files are searched.",
                       symbol: "magnifyingglass")
        } else if model.location == nil {
            emptyState("No Space selected", detail: "Select a Space in the Files sidebar", symbol: "folder")
        } else if let result = model.result, !result.files.isEmpty {
            resultList(result)
        } else if model.isSearching {
            emptyState("Searching…", detail: nil, symbol: "hourglass")
        } else if model.error == nil {
            emptyState("No Results", detail: "No results found in this Space for the provided query",
                       symbol: "doc.text.magnifyingglass")
        } else {
            Spacer()
        }
    }

    private func emptyState(_ title: String, detail: String?, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.system(size: typography.heading, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: typography.body)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultList(_ result: WorkspaceSearchResult) -> some View {
        let active = model.matches.indices.contains(model.activeMatch) ? model.matches[model.activeMatch] : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(result.files) { file in
                        fileHeader(file)
                        ForEach(Array(file.excerpts.enumerated()), id: \.offset) { index, excerpt in
                            if index > 0 {
                                Text("⋯").font(.system(size: typography.secondary)).foregroundStyle(.tertiary)
                                    .padding(.leading, 18).frame(height: 14)
                            }
                            ForEach(excerpt) { line in
                                lineRow(line, file: file, active: active)
                                    .id(file.path + ":" + String(line.number))
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .onChange(of: model.activeMatch) { _, _ in
                guard let active = activeRef else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(active.path + ":" + String(active.line), anchor: .center)
                }
            }
        }
    }

    private var activeRef: WorkspaceSearchMatchRef? {
        model.matches.indices.contains(model.activeMatch) ? model.matches[model.activeMatch] : nil
    }

    private func fileHeader(_ file: WorkspaceSearchFile) -> some View {
        Button {
            if let location = model.location { onOpen(location, file.path, 1, nil) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text((file.path as NSString).lastPathComponent).fontWeight(.semibold)
                Text((file.path as NSString).deletingLastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text("\(file.matchCount)")
                    .font(.system(size: typography.secondary, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: typography.body))
            .padding(.horizontal, 12)
            .frame(height: typography.metric(26))
            .background(Color.primary.opacity(0.04))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .help("Open \(file.path)")
    }

    private func lineRow(_ line: WorkspaceSearchLine, file: WorkspaceSearchFile,
                         active: WorkspaceSearchMatchRef?) -> some View {
        let isActiveLine = active?.path == file.path && active?.line == line.number
        let activeOccurrence = isActiveLine ? active?.occurrence : nil
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(line.number)")
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            Text(highlighted(line, activeOccurrence: activeOccurrence))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: typography.code, design: .monospaced))
        .padding(.trailing, 12)
        .frame(height: typography.metric(19))
        .background(isActiveLine ? theme.accent.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(line, file: file, occurrence: activeOccurrence ?? 0) }
        .onTapGesture {
            guard !line.matches.isEmpty,
                  let index = model.matches.firstIndex(of: WorkspaceSearchMatchRef(path: file.path, line: line.number,
                                                                                    occurrence: 0)) else { return }
            model.activeMatch = index
        }
        .help(line.matches.isEmpty ? "" : "Double-click to open at this match")
    }

    private func open(_ line: WorkspaceSearchLine, file: WorkspaceSearchFile, occurrence: Int) {
        guard let location = model.location else { return }
        let range = line.matches.indices.contains(occurrence) ? line.matches[occurrence] : nil
        onOpen(location, file.path, line.number, range)
    }

    func openActive() {
        guard let active = activeRef, let location = model.location,
              let file = model.result?.files.first(where: { $0.path == active.path }),
              let line = file.excerpts.joined().first(where: { $0.number == active.line }) else { return }
        onOpen(location, file.path, line.number,
               line.matches.indices.contains(active.occurrence) ? line.matches[active.occurrence] : nil)
    }

    /// Shows a window of long lines around the first match so it stays visible.
    private func highlighted(_ line: WorkspaceSearchLine, activeOccurrence: Int?) -> AttributedString {
        let text = line.text as NSString
        let start = max(0, (line.matches.first?.location ?? 0) - 40)
        let visible = NSRange(location: start, length: text.length - start)
        var output = AttributedString(start > 0 ? "…" : "")
        var cursor = visible.location
        for (index, match) in line.matches.enumerated() where match.location >= visible.location {
            output += AttributedString(text.substring(with: NSRange(location: cursor, length: match.location - cursor)))
            var piece = AttributedString(text.substring(with: match))
            piece.backgroundColor = index == activeOccurrence ? theme.warning.opacity(0.75) : theme.matchHighlight
            if index == activeOccurrence { piece.foregroundColor = theme.contentBackground }
            output += piece
            cursor = NSMaxRange(match)
        }
        output += AttributedString(text.substring(from: cursor).trimmingCharacters(in: .newlines))
        return output
    }
}
