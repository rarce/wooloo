import AppKit
import SwiftUI

struct WorkspaceGitHubRepository: Decodable, Equatable, Sendable {
    let nameWithOwner: String
    let url: String
    let hasIssuesEnabled: Bool
}

struct WorkspaceGitHubItem: Decodable, Identifiable, Equatable, Sendable {
    struct Author: Decodable, Equatable, Sendable { let login: String }
    let number: Int
    let title: String
    let url: String
    let author: Author?
    var isDraft: Bool?
    var id: Int { number }

    var browserURL: URL? {
        guard let url = URL(string: url), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

enum WorkspaceGitHubKind: String, CaseIterable, Sendable {
    case issues, prs
    var noun: String { self == .issues ? "issues" : "pull requests" }
    var arguments: [String] {
        let fields = "number,title,url,author" + (self == .prs ? ",isDraft" : "")
        return [self == .issues ? "issue" : "pr", "list", "--state", "open", "--limit", "50", "--json", fields]
    }
}

/// GitHub reads run on the Space's host using that host's existing gh credentials. All command
/// arguments are quoted individually for the shared local/SSH transport; no login is launched.
enum WorkspaceGitHub {
    static func command(_ arguments: [String]) -> String {
        """
        export GH_PROMPT_DISABLED=1 GH_PAGER=cat
        gh_path=$(command -v gh 2>/dev/null)
        if [ -z "$gh_path" ]; then
            for candidate in /opt/homebrew/bin/gh /usr/local/bin/gh "$HOME/.local/bin/gh"; do
                if [ -x "$candidate" ]; then gh_path=$candidate; break; fi
            done
        fi
        if [ -z "$gh_path" ]; then echo 'WOOL_GH_MISSING' >&2; exit 127; fi
        "$gh_path" \(arguments.map(WorkspaceFiles.quote).joined(separator: " "))
        """
    }

    static func repository(at location: WorkspaceFileLocation) throws -> WorkspaceGitHubRepository {
        let preflight = """
        git rev-parse --git-dir >/dev/null 2>&1 || { echo 'WOOL_GH_NO_REPOSITORY' >&2; exit 3; }
        [ -n "$(git remote)" ] || { echo 'WOOL_GH_NO_REMOTE' >&2; exit 3; }
        """
        let data = try WorkspaceFiles.shell(preflight + "\n" + command([
            "repo", "view", "--json", "nameWithOwner,url,hasIssuesEnabled"
        ]), at: location, limit: 64_000)
        return try JSONDecoder().decode(WorkspaceGitHubRepository.self, from: data)
    }

    static func items(_ kind: WorkspaceGitHubKind, repository: WorkspaceGitHubRepository,
                      at location: WorkspaceFileLocation) throws -> [WorkspaceGitHubItem] {
        let data = try WorkspaceFiles.shell(command(kind.arguments + ["--repo", repository.url]),
                                           at: location, limit: 512_000)
        return try JSONDecoder().decode([WorkspaceGitHubItem].self, from: data)
    }

    static func message(for error: Error, machine: String) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("wool_gh_missing") { return "Install GitHub CLI (gh) on \(machine), then retry." }
        if text.contains("wool_gh_no_repository") { return "This Space is not a Git repository." }
        if text.contains("wool_gh_no_remote") { return "This repository has no GitHub remote." }
        if text.contains("not a github") || text.contains("none of the git remotes") {
            return "This repository is not hosted on GitHub."
        }
        if text.contains("rate limit") { return "GitHub's request limit was reached. Retry after the limit resets." }
        if text.contains("auth login") || text.contains("authentication") || text.contains("401") || text.contains("bad credentials") {
            return "Sign in with gh auth login on \(machine), then retry."
        }
        if text.contains("403") || text.contains("404") || text.contains("could not resolve to a repository") {
            return "GitHub did not allow access to this repository. Check gh permissions on \(machine)."
        }
        return "Could not reach GitHub from \(machine). Check the connection and gh authentication, then retry."
    }
}

@MainActor
final class WorkspaceGitHubModel: ObservableObject {
    @Published private(set) var repository: WorkspaceGitHubRepository?
    @Published private(set) var items: [WorkspaceGitHubItem]?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var kind: WorkspaceGitHubKind?
    @Published private(set) var context: String?
    private var generation = UUID()
    private var repositories: [String: WorkspaceGitHubRepository] = [:]
    private var cache: [String: [WorkspaceGitHubItem]] = [:]

    typealias RepositoryLoader = @Sendable (WorkspaceFileLocation) async throws -> WorkspaceGitHubRepository
    typealias ItemsLoader = @Sendable (WorkspaceFileLocation, WorkspaceGitHubKind, WorkspaceGitHubRepository) async throws -> [WorkspaceGitHubItem]
    private let loadRepository: RepositoryLoader
    private let loadItems: ItemsLoader

    init(loadRepository: @escaping RepositoryLoader = { location in
        try await WorkspaceFiles.blocking(at: location) { try WorkspaceGitHub.repository(at: location) }
    }, loadItems: @escaping ItemsLoader = { location, kind, repository in
        try await WorkspaceFiles.blocking(at: location) {
            try WorkspaceGitHub.items(kind, repository: repository, at: location)
        }
    }) {
        self.loadRepository = loadRepository
        self.loadItems = loadItems
    }

    static func contextKey(_ location: WorkspaceFileLocation) -> String {
        location.identity + "|" + (location.machine?.target ?? "local")
    }

    func load(_ location: WorkspaceFileLocation?, kind: WorkspaceGitHubKind, refresh: Bool = false) async {
        let request = UUID()
        generation = request
        self.kind = kind
        let key = location.map(Self.contextKey)
        if context != key { repository = nil; items = nil }
        context = key
        error = nil
        guard let location, let key else { isLoading = false; return }
        let previous = repositories[key]
        repository = previous
        items = previous.flatMap { cache[key + "|" + $0.url + "|" + kind.rawValue] }
        if !refresh, previous != nil, items != nil { isLoading = false; return }
        isLoading = true
        defer { if generation == request { isLoading = false } }
        do {
            let repo: WorkspaceGitHubRepository
            if !refresh, let previous { repo = previous }
            else { repo = try await loadRepository(location) }
            guard !Task.isCancelled, generation == request else { return }
            // Bound the cache; host and Space identity isolate credentials and repository changes.
            if repositories.count >= 12, repositories[key] == nil { repositories.removeAll(); cache.removeAll() }
            repositories[key] = repo
            repository = repo
            let cacheKey = key + "|" + repo.url + "|" + kind.rawValue
            items = cache[cacheKey]
            if kind == .issues, !repo.hasIssuesEnabled { items = []; return }
            let entries = try await loadItems(location, kind, repo)
            guard !Task.isCancelled, generation == request else { return }
            items = entries
            cache[cacheKey] = entries
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            self.error = WorkspaceGitHub.message(for: error, machine: location.machineLabel)
        }
    }
}

struct WorkspaceGitHubView: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    let location: WorkspaceFileLocation?
    @Binding var isCollapsed: Bool
    @StateObject var model = WorkspaceGitHubModel()
    @State var selectedTab = "issues"
    @State private var reload = 0
    @State private var appliedReload = 0

    private var kind: WorkspaceGitHubKind { WorkspaceGitHubKind(rawValue: selectedTab) ?? .issues }
    private var loadKey: String { "\(location.map(WorkspaceGitHubModel.contextKey) ?? "none")|\(selectedTab)|\(isCollapsed)|\(reload)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Button { isCollapsed.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: typography.tiny, weight: .semibold))
                        Text("GITHUB").tracking(0.7)
                    }
                    .font(.system(size: typography.secondary, weight: .semibold))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Show GitHub" : "Hide GitHub")
                Spacer(minLength: 0)
                Button { reload += 1 } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: typography.secondary))
                        .opacity(model.isLoading ? 0 : 1)
                        .overlay { if model.isLoading { ProgressView().controlSize(.mini) } }
                }
                .buttonStyle(.plain)
                .disabled(model.isLoading || location == nil || isCollapsed)
                .help("Refresh GitHub")
            }
            .padding(.horizontal, 11)
            .frame(height: typography.metric(35))
            if !isCollapsed {
                Divider()
                PanelTabStrip(tabs: PanelTab.github, selection: $selectedTab)
                Divider()
                if model.context == location.map(WorkspaceGitHubModel.contextKey), let repository = model.repository {
                    Text(repository.nameWithOwner)
                        .font(.system(size: typography.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .help(repository.url)
                }
                content
            }
        }
        .background(theme.sidebarBackground)
        .task(id: loadKey) {
            guard !isCollapsed else { return }
            let forceRefresh = reload != appliedReload
            appliedReload = reload
            await model.load(location, kind: kind, refresh: forceRefresh)
        }
    }

    @ViewBuilder private var content: some View {
        if location == nil {
            hint("Select a Space to browse GitHub.")
        } else if model.context != location.map(WorkspaceGitHubModel.contextKey) || model.kind != kind || (model.isLoading && model.items == nil) {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 5) {
                        if model.items != nil { Text("Showing previous results").fontWeight(.medium) }
                        Text(error)
                        Button("Retry") { reload += 1 }.buttonStyle(.link).disabled(model.isLoading)
                    }
                    .font(.system(size: typography.caption))
                    .foregroundStyle(.secondary)
                    .padding(11)
                }
                if kind == .issues && model.repository?.hasIssuesEnabled == false {
                    hint("Issues are disabled for this repository.")
                } else if let items = model.items {
                    if items.isEmpty { hint("No open \(kind.noun).") }
                    else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(items) { item in row(item) }
                                if items.count == 50 {
                                    Text("Showing the first 50 \(kind.noun)")
                                        .font(.system(size: typography.caption)).foregroundStyle(.secondary)
                                        .padding(11)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: typography.body)).foregroundStyle(.secondary)
            .padding(11).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ item: WorkspaceGitHubItem) -> some View {
        Button {
            if let url = item.browserURL { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: kind == .issues ? "circle.dotted" : "arrow.triangle.pull")
                    .foregroundStyle(item.isDraft == true ? Color.secondary : theme.accent)
                    .frame(width: 15).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: typography.body)).lineLimit(2)
                    Text("#\(item.number)" + (item.author.map { " · \($0.login)" } ?? "") + (item.isDraft == true ? " · Draft" : ""))
                        .font(.system(size: typography.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open #\(item.number) in browser")
        .contextMenu {
            Button("Open in Browser", systemImage: "arrow.up.right.square") {
                if let url = item.browserURL { NSWorkspace.shared.open(url) }
            }
            Button("Copy URL", systemImage: "doc.on.doc") { AppActions.copy(item.url) }
        }
    }
}
