import AppKit
import Combine
import SwiftUI

/// Checked on the worker after acquiring its machine slot, before sending any request.
final class HerdrRequestToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isValid: Bool { lock.withLock { !cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if !isValid { throw CancellationError() } }
}

/// A reference captured when an action opens a dialog, rather than when it is confirmed.
@MainActor
struct HerdrActionConnection {
    let store: HerdrStore
    let generation: Int
    let epoch: UUID

    init(_ store: HerdrStore) {
        self.store = store
        generation = store.generation
        epoch = store.actionEpoch
    }

    var validStore: HerdrStore? { store.generation == generation && store.actionEpoch == epoch && store.isConnected ? store : nil }
}

/// One passive API subscription and SSH bridge per destination across all windows.
/// A lease lasts until the destination is removed or its last window closes.
@MainActor
final class HerdrMetadataPool {
    static let shared = HerdrMetadataPool()
    private struct Entry {
        let store: HerdrStore
        let subscription: AnyCancellable
        var users: Int
    }
    private var entries: [String: Entry] = [:]
    private let notifier: HerdrNotifier
    let profiles = CurrentValueSubject<[HerdrMachineProfile]?, Never>(nil)

    init(notifier: HerdrNotifier? = nil) { self.notifier = notifier ?? .shared }

    private func key(machine: HerdrMachineProfile?, session: String) -> String {
        // Target changes invalidate the live connection even when the saved profile ID stays.
        [machine?.id ?? "local", session, machine?.target ?? ""].map { "\($0.utf8.count):\($0)" }.joined()
    }

    func acquire(machine: HerdrMachineProfile?, session: String) -> HerdrStore {
        let id = key(machine: machine, session: session)
        if var entry = entries[id] {
            entry.users += 1
            entries[id] = entry
            if let machine { entry.store.updateProfile(machine) }
            return entry.store
        }
        let store = HerdrStore()
        store.setPresentationActive(false)
        if let machine { store.connect(to: machine) } else { store.connect(to: session, remember: false) }
        let subscription = store.snapshotPublisher.sink { [weak self, weak store] snapshot in
            guard let self, let store else { return }
            notifier.process(snapshot, selectedPaneID: nil, contextID: store.contextID)
        }
        entries[id] = Entry(store: store, subscription: subscription, users: 1)
        return store
    }

    func release(_ store: HerdrStore) {
        guard let id = entries.first(where: { $0.value.store === store })?.key,
              var entry = entries[id] else { return }
        entry.users -= 1
        if entry.users == 0 {
            store.stop()
            notifier.forget(contextID: store.contextID)
            entries[id] = nil
        }
        else { entries[id] = entry }
    }
}

/// Metadata and selection survive a window switching to another destination. A background
/// store subscribes only to the JSON API: it never opens a terminal endpoint or polls pane text.
@MainActor
final class HerdrDestinations: ObservableObject {
    @Published private(set) var stores: [HerdrStore]
    @Published private(set) var active: HerdrStore
    @Published private(set) var previous: HerdrStore?
    private(set) var lastLocal: HerdrStore?
    @Published private(set) var catalogError: String?
    @Published private(set) var sessionSelectionError: String?
    private(set) var isRunning = false
    private var subscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var catalogSubscription: AnyCancellable?
    private var navigation = UUID()
    private var previousSelection: (space: String?, tab: String?, pane: String?)?
    @Published private(set) var terminalRequestID = UUID()
    private var terminalRequest: (context: String, pane: String)?
    private var acknowledgeTask: Task<Void, Never>?
    var onOpenTerminal: () -> Void = {}
    var isTerminalVisible: () -> Bool = { true }
    private let notifier: HerdrNotifier
    private let pool: HerdrMetadataPool?
    let windowID = UUID()
    weak var nativeWindow: NSWindow?

    init(store: HerdrStore? = nil, notifier: HerdrNotifier? = nil,
         pool: HerdrMetadataPool? = nil) {
        let store = store ?? HerdrStore()
        active = store
        lastLocal = store.machine == nil ? store : nil
        stores = [store]
        self.notifier = notifier ?? .shared
        self.pool = pool
        store.requiresSurfaceForInput = true
    }

    func start() {
        isRunning = true
        if catalogSubscription == nil, let pool {
            catalogSubscription = pool.profiles.sink { [weak self] profiles in
                if let profiles { self?.applyCatalog(profiles) }
            }
        }
        for store in stores {
            attachMetadata(store)
            observe(store)
            store.start()
        }
        notifier.register(windowID, window: { [weak self] in self?.nativeWindow },
                          watched: { [weak self] in
            guard let self, nativeWindow?.isKeyWindow == true, active.inputReady, isTerminalVisible(),
                  let pane = active.selectedPaneID else { return nil }
            return (active.contextID, pane)
        }, open: { [weak self] context, pane in self?.open(context: context, pane: pane) ?? false })
    }

    func stop() {
        isRunning = false
        acknowledgeTask?.cancel()
        navigation = UUID()
        notifier.unregister(windowID)
        subscriptions.removeAll()
        catalogSubscription?.cancel()
        catalogSubscription = nil
        for store in stores {
            store.stop()
            if let source = store.metadataSource { pool?.release(source) }
            store.metadataSource = nil
        }
    }

    private func attachMetadata(_ store: HerdrStore) {
        guard store.destinationEnabled, let pool, store.metadataSource == nil else { return }
        store.metadataSource = pool.acquire(machine: store.machine, session: store.sessionName)
    }

    private func observe(_ store: HerdrStore) {
        guard pool == nil else { return }
        let key = ObjectIdentifier(store)
        guard subscriptions[key] == nil else { return }
        subscriptions[key] = store.snapshotPublisher.sink { [weak self, weak store] snapshot in
            guard let self, let store else { return }
            notifier.process(snapshot, selectedPaneID: nil, contextID: store.contextID)
        }
    }

    func refresh(_ machines: [HerdrMachineProfile]) {
        guard isRunning else { return }
        if let pool { pool.profiles.send(machines) }
        else { applyCatalog(machines) }
    }

    private func applyCatalog(_ machines: [HerdrMachineProfile]) {
        guard isRunning else { return }
        catalogError = nil
        let enabled = machines.filter(\.enabled)
        guard enabled.allSatisfy({ $0.session.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil }) else {
            catalogError = "A saved host has an invalid Herdr session. Current connections were kept unchanged."
            return
        }
        // Removing/disabling a selected host never silently redirects actions to Local.
        // Keep that destination visible until the user explicitly leaves it.
        for store in stores where store.machine != nil && store !== active {
            if !enabled.contains(where: { $0.id == store.machine?.id }) {
                store.stop()
                if let source = store.metadataSource { pool?.release(source) }
                store.metadataSource = nil
                subscriptions.removeValue(forKey: ObjectIdentifier(store))
            }
        }
        stores.removeAll { store in
            store !== active && store.machine != nil && !enabled.contains { $0.id == store.machine?.id }
        }
        if let profile = active.machine, !enabled.contains(where: { $0.id == profile.id }) {
            active.setDestinationEnabled(false)
            if let source = active.metadataSource { pool?.release(source) }
            active.metadataSource = nil
        }
        for profile in enabled {
            if let existing = stores.first(where: { $0.machine?.id == profile.id }) {
                if !existing.destinationEnabled {
                    existing.metadataSource = pool?.acquire(machine: profile, session: profile.session)
                    existing.setDestinationEnabled(true)
                }
                if existing.machine != profile {
                    // Label-only changes do not reconnect or invalidate document identity.
                    if existing.machine?.target != profile.target || existing.sessionName != profile.session {
                        existing.stop()
                        if let source = existing.metadataSource { pool?.release(source) }
                        existing.metadataSource = pool?.acquire(machine: profile, session: profile.session)
                    }
                    existing.updateProfile(profile)
                    existing.metadataSource?.updateProfile(profile)
                }
            } else {
                let store = HerdrStore()
                store.requiresSurfaceForInput = true
                store.setPresentationActive(false)
                store.metadataSource = pool?.acquire(machine: profile, session: profile.session)
                store.connect(to: profile)
                stores.append(store)
                observe(store)
            }
        }
    }

    func reportCatalogError(_ error: Error) { catalogError = error.localizedDescription }

    func select(_ store: HerdrStore, workspaceID: String? = nil) {
        terminalRequest = nil
        navigation = UUID()
        if store !== active || (workspaceID != nil && workspaceID != active.selectedWorkspaceID) {
            previous = active
            previousSelection = (active.selectedWorkspaceID, active.selectedTabID, active.selectedPaneID)
        }
        if store !== active {
            active.setPresentationActive(false)
            active = store
        }
        if store.machine == nil {
            lastLocal = store
            UserDefaults.standard.set(store.sessionName, forKey: "HerdrLastSession")
        }
        if let workspaceID { store.select(workspaceID: workspaceID) }
        store.setPresentationActive(true)
        store.start()
    }

    func goBack() {
        guard let previous, stores.contains(where: { $0 === previous }) else { return }
        let selection = previousSelection
        select(previous, workspaceID: selection?.space)
        if let tab = selection?.tab, previous.snapshot?.tabs.contains(where: { $0.tabID == tab && $0.workspaceID == previous.selectedWorkspaceID }) == true {
            previous.select(tabID: tab)
        }
        if let pane = selection?.pane { previous.select(paneID: pane) }
    }

    func localSession(_ requestedName: String) {
        guard isRunning else { return }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            sessionSelectionError = "Use letters, numbers, hyphens, or underscores"
            return
        }
        sessionSelectionError = nil
        if let store = stores.first(where: { $0.machine == nil && $0.sessionName == name }) {
            select(store)
            return
        }
        let store = HerdrStore()
        store.requiresSurfaceForInput = true
        store.setPresentationActive(false)
        store.metadataSource = pool?.acquire(machine: nil, session: name)
        store.connect(to: name)
        guard store.sessionSelectionError == nil else { return }
        stores.insert(store, at: stores.firstIndex(where: { $0.machine != nil }) ?? stores.endIndex)
        observe(store)
        select(store)
    }

    func createSpace(on store: HerdrStore, cwd: String? = nil, label: String? = nil) {
        let intent = navigation
        let previousContext = (active.contextID, active.selectedWorkspaceID, active.selectedTabID, active.selectedPaneID)
        store.createWorkspace(cwd: cwd, label: label, selectOnOpen: false) { [weak self, weak store] id in
            guard let self, let store, navigation == intent,
                  active.contextID == previousContext.0, active.selectedWorkspaceID == previousContext.1,
                  active.selectedTabID == previousContext.2, active.selectedPaneID == previousContext.3 else { return }
            select(store, workspaceID: id)
        }
    }

    private func open(context: String, pane: String) -> Bool {
        guard let store = stores.first(where: { $0.contextID == context }),
              let target = store.snapshot?.panes.first(where: { $0.paneID == pane }) else { return false }
        nativeWindow?.makeKeyAndOrderFront(nil)
        onOpenTerminal()
        select(store, workspaceID: target.workspaceID)
        store.select(tabID: target.tabID)
        store.select(paneID: pane)
        terminalRequest = (context, pane)
        terminalRequestID = UUID()
        acknowledgeVisiblePane()
        return true
    }

    var wantsTerminal: Bool {
        terminalRequest?.context == active.contextID && terminalRequest?.pane == active.selectedPaneID
    }

    func acknowledgeVisiblePane() {
        acknowledgeTask?.cancel()
        let store = active
        let intent = navigation
        guard let pane = store.selectedPaneID else { return }
        acknowledgeTask = Task { [weak self, weak store] in
            for _ in 0..<60 {
                guard !Task.isCancelled, let self, let store, navigation == intent,
                      nativeWindow?.isKeyWindow == true else { return }
                if store.inputReady, store.surface?.focusedPaneID == pane, isTerminalVisible() {
                    notifier.acknowledge(paneID: pane, contextID: store.contextID)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

}

/// Captures the actual window so a notification opens in one window and watched panes are
/// acknowledged only in the frontmost window, rather than in every open destination.
struct DestinationWindowObserver: NSViewRepresentable {
    let destinations: HerdrDestinations
    func makeNSView(context: Context) -> WindowView { WindowView(destinations) }
    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        let destinations: HerdrDestinations
        init(_ destinations: HerdrDestinations) {
            self.destinations = destinations
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { destinations.nativeWindow = window }
    }
}

struct HerdrDestinationSection: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject var notifier: HerdrNotifier
    let active: Bool
    let grouped: Bool
    let select: (String) -> Void
    let create: () -> Void
    let rename: (HerdrWorkspace) -> Void
    let close: (HerdrWorkspace) -> Void
    @State private var collapsed = false
    @Environment(\.woolooTheme) private var theme
    @Environment(\.woolooTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if grouped {
                HStack(spacing: 4) {
                    Button { collapsed.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            Text("\(store.machine?.label ?? "Local") · \(store.sessionName)").lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(store.errorMessage ?? "Expand or collapse Spaces")
                    let marks = (store.snapshot ?? store.cachedSnapshot)?.workspaces.reduce((requests: 0, done: 0)) { sum, space in
                        let count = notifier.attentionCount(inWorkspace: space.workspaceID,
                            snapshot: store.snapshot ?? store.cachedSnapshot, contextID: store.contextID)
                        return (sum.requests + count.requests, sum.done + count.done)
                    }
                    HerdrAttentionBadge(requests: marks?.requests ?? 0, done: marks?.done ?? 0)
                    Image(systemName: store.isConnected ? "circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 7))
                        .foregroundStyle(store.isConnected ? theme.accent : theme.warning)
                        .help(store.isConnected ? "Connected" : store.errorMessage ?? "Connecting")
                    Button(action: create) { Image(systemName: "plus") }
                        .buttonStyle(.plain).disabled(!store.isConnected)
                        .help("New Space on \(store.machine?.label ?? "Local") · \(store.sessionName)")
                }
                .font(.system(size: typography.secondary, weight: .medium))
                .padding(.vertical, 4)
            }
            if !collapsed {
                if !store.isConnected {
                    Text(store.cachedSnapshot == nil ? "Connecting…" : "Disconnected · last known Spaces")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.errorMessage != nil {
                        Button("Reconnect") { store.stop(); store.start() }.buttonStyle(.plain)
                            .font(.caption).disabled(!store.destinationEnabled)
                    }
                }
                ForEach((store.snapshot ?? store.cachedSnapshot)?.workspaces ?? []) { space in
                    Button { select(space.workspaceID) } label: {
                        HStack(spacing: 7) {
                            AgentStatusDot(status: space.agentStatus)
                            Text(space.label).lineLimit(1)
                            Spacer(minLength: 0)
                            if let git = store.workspaceGitStatuses[space.workspaceID] {
                                HStack(spacing: 4) {
                                    if git.ahead > 0 { Text("↑\(git.ahead)") }
                                    if git.behind > 0 { Text("↓\(git.behind)") }
                                }
                                .font(.system(size: typography.secondary)).monospacedDigit()
                                .foregroundStyle(.secondary).fixedSize()
                            }
                            let marks = notifier.attentionCount(inWorkspace: space.workspaceID,
                                snapshot: store.snapshot ?? store.cachedSnapshot, contextID: store.contextID)
                            HerdrAttentionBadge(requests: marks.requests, done: marks.done)
                        }
                        .font(.system(size: typography.emphasis, weight: .medium))
                        .sidebarRow(selected: active && store.selectedWorkspaceID == space.workspaceID)
                        .opacity(store.isConnected ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("New Tab in Space", systemImage: "plus") {
                            select(space.workspaceID)
                            store.createTab()
                        }.disabled(!store.isConnected)
                        Button("Rename Space…", systemImage: "pencil") { rename(space) }
                            .disabled(!store.isConnected)
                        if let snapshot = store.snapshot,
                           let location = WorkspaceFiles.location(snapshot: snapshot, workspaceID: space.workspaceID,
                               session: store.sessionName, machine: store.machine) {
                            Button("Copy Path", systemImage: "doc.on.doc") { AppActions.copy(location.root) }
                            if location.isLocal {
                                Button("Reveal in Finder", systemImage: "folder") { AppActions.reveal(location.root) }
                            }
                        }
                        Button("Close Space…", systemImage: "xmark", role: .destructive) { close(space) }.disabled(!store.isConnected)
                    }
                }
                if let error = store.actionError {
                    Text(error).font(.caption).foregroundStyle(theme.warning)
                }
            }
        }
        .onChange(of: active) { _, active in if active { collapsed = false } }
        .onChange(of: store.selectedWorkspaceID) { _, _ in if active { collapsed = false } }
    }
}
