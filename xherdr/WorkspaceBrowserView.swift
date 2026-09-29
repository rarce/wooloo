import SwiftUI

struct WorkspaceBrowserView: View {
    let localSnapshot: HerdrSnapshot?
    let localWorkspaceID: String?
    let localSession: String
    let refreshVersion: Int
    let onOpenFile: (WorkspaceFileLocation, String) -> Void
    let onOpenDiff: (WorkspaceFileLocation, String) -> Void

    @State private var machines: [HerdrMachineProfile] = []
    @State private var selectedMachineID = "local"
    @State private var remoteSnapshot: HerdrSnapshot?
    @State private var remoteWorkspaceID: String?
    @State private var listing: WorkspaceFileListing?
    @State private var error: String?
    @State private var isLoading = false
    @State private var showsChanges = false

    private var machine: HerdrMachineProfile? {
        machines.first { $0.id == selectedMachineID }
    }

    private var snapshot: HerdrSnapshot? {
        machine == nil ? localSnapshot : remoteSnapshot
    }

    private var workspaceID: String? {
        machine == nil ? localWorkspaceID : remoteWorkspaceID
    }

    private var location: WorkspaceFileLocation? {
        guard let snapshot, let workspaceID else { return nil }
        return WorkspaceFiles.location(snapshot: snapshot, workspaceID: workspaceID,
                                       session: machine?.session ?? localSession, machine: machine)
    }

    private var listingIdentity: String {
        (location?.identity ?? "none|\(selectedMachineID)|\(workspaceID ?? "")") + "|\(refreshVersion)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EXPLORER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
                Spacer()
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Refresh files and changes")
            }
            .padding(.horizontal, 11)
            .frame(height: 35)
            Divider()

            HStack(spacing: 5) {
                Menu {
                    Button("Local") { selectMachine("local") }
                    ForEach(machines) { profile in
                        Button(profile.label) { selectMachine(profile.id) }
                    }
                } label: {
                    Label(machine?.label ?? "Local", systemImage: "desktopcomputer")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .frame(height: 27)

            if let snapshot, machine != nil {
                Menu {
                    ForEach(snapshot.workspaces) { workspace in
                        Button(workspace.label) { remoteWorkspaceID = workspace.workspaceID }
                    }
                } label: {
                    Label(snapshot.workspaces.first(where: { $0.workspaceID == remoteWorkspaceID })?.label ?? "Choose Space",
                          systemImage: "square.stack")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 9)
                .frame(height: 26)
            } else {
                Text(location?.workspaceLabel ?? "Select a Space")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .frame(height: 26, alignment: .leading)
            }

            HStack(spacing: 2) {
                segment("Files", icon: "doc.text", selected: !showsChanges) { showsChanges = false }
                segment("Changes", icon: "arrow.left.arrow.right", selected: showsChanges) { showsChanges = true }
            }
            .padding(4)
            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let listing, let location {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if showsChanges {
                            if !listing.hasGit {
                                hint("No Git repository in this Space")
                            } else if listing.changes.isEmpty {
                                hint("No changes")
                            }
                            ForEach(listing.changes) { change in
                                Button { onOpenDiff(location, change.path) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.left.arrow.right")
                                            .foregroundStyle(.cyan)
                                        Text(change.path).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        Text(change.statusLabel)
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 9)
                                    .frame(height: 25)
                                }
                                .buttonStyle(.plain)
                                .help(change.path)
                            }
                        } else {
                            if listing.files.isEmpty { hint("No files") }
                            ForEach(listing.files, id: \.self) { path in
                                Button { onOpenFile(location, path) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.text")
                                            .foregroundStyle(.secondary)
                                        Text(path).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 9)
                                    .frame(height: 25)
                                }
                                .buttonStyle(.plain)
                                .help(path)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
                .id(showsChanges ? "changes|\(location.identity)" : "files|\(location.identity)")
            } else {
                hint("Select a Space to browse")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(red: 0.105, green: 0.115, blue: 0.13))
        .task { loadMachines() }
        .task(id: listingIdentity) { loadListing() }
    }

    private func segment(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .background(selected ? Color.white.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func hint(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(10)
    }

    private func selectMachine(_ id: String) {
        selectedMachineID = id
        remoteSnapshot = nil
        remoteWorkspaceID = nil
        listing = nil
        error = nil
        if let machine { loadRemote(machine) }
    }

    private func refresh() {
        loadMachines()
        if let machine { loadRemote(machine) }
        else { loadListing() }
    }

    private func loadMachines() {
        Task {
            let result = await Task.detached { Result { try WorkspaceFiles.machines() } }.value
            if case .success(let profiles) = result { machines = profiles }
        }
    }

    private func loadRemote(_ profile: HerdrMachineProfile) {
        isLoading = true
        error = nil
        Task {
            let result = await Task.detached { Result { try WorkspaceFiles.remoteSnapshot(profile) } }.value
            guard selectedMachineID == profile.id else { return }
            switch result {
            case .success(let snapshot):
                remoteSnapshot = snapshot
                remoteWorkspaceID = snapshot.focusedWorkspaceID ?? snapshot.workspaces.first?.workspaceID
            case .failure(let failure):
                error = failure.localizedDescription
                isLoading = false
            }
        }
    }

    private func loadListing() {
        guard let location else { listing = nil; return }
        isLoading = true
        error = nil
        Task {
            let result = await Task.detached { Result { try WorkspaceFiles.listing(at: location) } }.value
            guard self.location?.identity == location.identity else { return }
            switch result {
            case .success(let value): listing = value
            case .failure(let failure): error = failure.localizedDescription
            }
            isLoading = false
        }
    }
}
