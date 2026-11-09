import AppKit
import SwiftUI

/// One surface for per-window membership and Herdr-owned SSH profile administration.
struct HerdrConnectionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var destinations: HerdrDestinations
    @ObservedObject var documents: WorkspaceDocumentStore
    @ObservedObject var catalog: HerdrConnectionCatalog
    @ObservedObject var runtime: HerdrRuntimeModel
    let closeConnection: (HerdrStore) async -> Void
    @State private var selection: String?
    @State private var operation = false
    @State private var error: String?
    @State private var adding = false
    @State private var isSSH = false
    @State private var session = "default"
    @State private var target = ""
    @State private var label = ""
    @State private var rename: HerdrMachineProfile?
    @State private var newLabel = ""
    @State private var confirmation: ProfileAction?

    private struct ProfileAction: Identifiable {
        let profile: HerdrMachineProfile
        let command: String
        var id: String { profile.id + command }
        var title: String {
            switch command {
            case "remove": "Remove saved SSH profile?"
            case "disable": "Disable SSH profile?"
            default: "Enable SSH profile?"
            }
        }
    }

    private var connections: [HerdrWindowConnection] {
        var result = catalog.sessions.map { HerdrWindowConnection(session: $0.name) }
        for item in destinations.stores.filter({ $0.machine == nil }).map(HerdrWindowConnection.init)
            + destinations.retired.filter({ $0.machine == nil }) where !result.contains(where: { $0.id == item.id }) {
            result.append(item)
        }
        result.sort { $0.session == "default" ? $1.session != "default" : $1.session != "default" && $0.session < $1.session }
        for profile in catalog.machines {
            result.append(HerdrWindowConnection(session: profile.session, machine: profile))
        }
        for item in destinations.stores.map(HerdrWindowConnection.init) + destinations.retired
            where item.machine != nil && !result.contains(where: { $0.id == item.id }) {
            result.append(item)
        }
        return result
    }
    private var selected: HerdrWindowConnection? { connections.first { $0.id == selection } }
    private var drafts: [WorkspaceDocument] { documents.preservedTextDrafts }
    private func opened(_ connection: HerdrWindowConnection) -> HerdrStore? {
        destinations.stores.first { $0.contextID == connection.id }
    }
    private func nativeSession(_ connection: HerdrWindowConnection) -> HerdrLocalSession? {
        catalog.sessions.first { $0.name == connection.session }
    }
    private func status(_ connection: HerdrWindowConnection) -> String {
        if let store = opened(connection), store.isConnected { return "Connected" }
        if let profile = connection.machine {
            if !catalog.machinesLoaded { return "Checking saved profile…" }
            if !catalog.machines.contains(where: { $0 == profile }) { return "Profile changed or removed" }
            return profile.enabled ? "Server state not verified" : "Profile disabled"
        }
        return nativeSession(connection)?.status ?? "State not verified"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connections").font(.title2.bold())
                    Text("Computers and Herdr sessions").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add…", systemImage: "plus") { adding = true }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HSplitView {
                List(selection: $selection) {
                    ForEach(connections) { connection in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(connection.label, systemImage: connection.machine == nil ? "desktopcomputer" : "network")
                                .fontWeight(.medium)
                            Text(status(connection)).font(.caption).foregroundStyle(.secondary)
                            Text(opened(connection) == nil ? "Not open in this window" : "Open in this window")
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                        .tag(connection.id)
                    }
                }
                .frame(minWidth: 245, idealWidth: 280)
                Group {
                    if let selected { detail(selected) }
                    else { ContentUnavailableView("Choose a connection", systemImage: "network") }
                }
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 18)
            }
            .frame(minHeight: 280, idealHeight: 350)
            if !drafts.isEmpty {
                DisclosureGroup("Preserved drafts (\(drafts.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(drafts) { document in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(document.title)
                                        Text("\(document.location.machineLabel) · \(document.location.session) · \(document.location.workspaceLabel)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Save a Copy…") { export(document) }
                                }
                            }
                        }
                    }.frame(maxHeight: 130)
                }
            }
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { catalog.refresh() }
                if catalog.busy || operation { ProgressView().controlSize(.small) }
                Spacer()
                Text("Herdr: \(HerdrRuntimePaths.configRoot.path)").font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let error = error ?? catalog.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 760)
        .disabled(operation)
        .interactiveDismissDisabled(operation)
        .onAppear {
            selection = destinations.isActiveDestinationOpen ? destinations.active.contextID : destinations.retired.last?.id
            catalog.refresh()
        }
        .task(id: destinations.recoverySpaces) { await documents.recoverConnectionDrafts(in: destinations.recoverySpaces) }
        .sheet(isPresented: $adding) { addForm }
        .alert("Rename SSH Profile", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("Label", text: $newLabel)
            Button("Save") {
                if let rename { perform(["rename", rename.id, "--label", newLabel], expected: rename) }
                rename = nil
            }.disabled(newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { rename = nil }
        }
        .alert(confirmation?.title ?? "SSH profile", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("Confirm", role: confirmation?.command == "enable" ? nil : .destructive) {
                if let confirmation { perform([confirmation.command, confirmation.profile.id], expected: confirmation.profile) }
                confirmation = nil
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text("\(confirmation?.profile.label ?? "") · \(confirmation?.profile.target ?? "") · \(confirmation?.profile.session ?? "")\n\nThis changes Herdr's saved catalog for every client using it. Remote files and sessions remain on the host.")
        }
    }

    @ViewBuilder
    private func detail(_ connection: HerdrWindowConnection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(connection.session).font(.title3.weight(.semibold)).textSelection(.enabled)
            Text(connection.machine.map { "SSH · \($0.label) · \($0.target)" } ?? "Local · This Mac")
                .foregroundStyle(.secondary).textSelection(.enabled)
            Text(status(connection))
            if let native = nativeSession(connection), connection.machine == nil, let failure = native.connectionError {
                Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let store = opened(connection) {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Show in This Window") { destinations.select(store); dismiss() }
                        .disabled(!store.destinationEnabled)
                    Button("Remove from This Window", systemImage: "xmark") {
                        operation = true
                        Task { await closeConnection(store); operation = false }
                    }
                }
                Text("Removing closes only this window's connection. Herdr keeps the session and its data.")
                    .font(.caption).foregroundStyle(.secondary)
                if connection.machine == nil, nativeSession(connection)?.isVerifiedStopped == true {
                    Button("Start and Connect") { open(connection, start: true) }
                }
            } else if let profile = connection.machine {
                if catalog.machines.contains(profile) {
                    Button("Open in This Window") { openRemote(profile) }
                        .buttonStyle(.borderedProminent).disabled(!profile.enabled || !catalog.machinesLoaded)
                } else {
                    Text("This profile has changed or was removed. Its previous context and drafts are preserved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let native = nativeSession(connection) {
                Button(native.isVerifiedStopped ? "Start and Open" : native.running ? "Open in This Window" : "Check State") {
                    if native.connectionError != nil { catalog.refresh() }
                    else { open(connection, start: native.isVerifiedStopped) }
                }.buttonStyle(.borderedProminent)
            } else {
                Button("Check State") { catalog.refresh() }
            }
            if let profile = connection.machine, catalog.machines.contains(profile) {
                Divider()
                Text("Saved SSH profile").fontWeight(.medium)
                Text("Changes affect clients that use this Herdr catalog.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Rename…") { rename = profile; newLabel = profile.label }
                    Button(profile.enabled ? "Disable…" : "Enable…") {
                        confirmation = ProfileAction(profile: profile, command: profile.enabled ? "disable" : "enable")
                    }
                }
                Button("Remove Saved Profile…", role: .destructive) {
                    confirmation = ProfileAction(profile: profile, command: "remove")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Connection").font(.title2.bold())
            Picker("Type", selection: $isSSH) {
                Text("Local session").tag(false)
                Text("SSH profile").tag(true)
            }.pickerStyle(.segmented)
            TextField("Herdr session", text: $session)
            if isSSH {
                TextField("SSH alias, user@host, or ssh://user@host:port", text: $target)
                TextField("Label (optional)", text: $label)
                Text("Herdr prepares the server before saving. SSH aliases, keys and host trust use OpenSSH. Complete any authentication in Terminal first.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Creates or starts the named local Herdr server and opens it in this window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { adding = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isSSH ? "Prepare, Save and Open" : "Create/Start and Open") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!HerdrSessionName.isValid(session.trimmingCharacters(in: .whitespacesAndNewlines))
                              || (isSSH && (target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.hasPrefix("-"))))
            }
        }.padding(20).frame(width: 500).disabled(operation).interactiveDismissDisabled(operation)
    }

    private func open(_ connection: HerdrWindowConnection, start: Bool) {
        operation = true
        Task {
            defer { operation = false }
            let checked = await BlockingWork.run { Result { try WorkspaceFiles.localSessions() } }
            let current: HerdrLocalSession?
            do {
                current = try checked.get().first { $0.name == connection.session }
                if let failure = current?.connectionError { throw WorkspaceFileError.message(failure) }
                if !start, current?.running != true {
                    throw WorkspaceFileError.message("The session is no longer running. Refresh it, then choose Start and Open.")
                }
            } catch { self.error = error.localizedDescription; return }
            if start {
                guard await runtime.startServer(session: connection.session) else {
                    error = runtime.serverStartError ?? "Another Herdr operation is running. Retry when it finishes."
                    return
                }
            }
            guard destinations.isRunning else { return }
            destinations.localSession(connection.session)
            selection = connection.id
            catalog.refresh()
        }
    }

    private func openRemote(_ profile: HerdrMachineProfile) {
        operation = true
        Task {
            defer { operation = false }
            guard let profiles = await catalog.freshMachines(), profiles.contains(profile) else {
                error = "The saved profile could not be verified or has changed. Refresh and choose it again."
                return
            }
            destinations.refresh(profiles)
            destinations.openMachine(profile)
        }
    }

    private func add() {
        let name = session.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isSSH {
            adding = false
            // The session might have changed since the catalog was read. Do not turn an
            // authentication/permission error into an attempted server start.
            if let known = catalog.sessions.first(where: { $0.name == name }), known.connectionError != nil {
                error = "The session state could not be verified. Refresh it before starting."
                return
            }
            open(HerdrWindowConnection(session: name), start: true)
            return
        }
        let ssh = target.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["add", ssh, "--remote-session", name]
        if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { arguments += ["--label", label] }
        let oldIDs = Set(catalog.machines.map(\.id))
        operation = true
        Task {
            defer { operation = false }
            do {
                try await catalog.manage(arguments)
                destinations.refresh(catalog.machines)
                if let profile = catalog.machines.first(where: { !oldIDs.contains($0.id) && $0.target == ssh && $0.session == name }) {
                    destinations.openMachine(profile)
                    selection = profile.contextID(session: name)
                }
                adding = false
            } catch { self.error = error.localizedDescription; adding = false }
        }
    }

    private func perform(_ arguments: [String], expected: HerdrMachineProfile) {
        guard catalog.machines.contains(expected) else {
            error = "The SSH profile changed. Refresh and try again."
            return
        }
        operation = true
        Task {
            defer { operation = false }
            do {
                try await documents.flushPersistence()
                try await catalog.manage(arguments, expected: expected)
                destinations.refresh(catalog.machines)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func export(_ document: WorkspaceDocument) {
        guard document.canSave else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.isUntitled ? "Draft.txt" : (document.path as NSString).lastPathComponent
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = document.text
            Task {
                let result = await BlockingWork.run { Result { try Data(text.utf8).write(to: url, options: .atomic) } }
                if case .failure(let failure) = result { error = failure.localizedDescription }
            }
        }
    }
}
