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
    @Published private(set) var retired: [HerdrWindowConnection] = []
    var isActiveDestinationOpen: Bool { stores.contains { $0 === active } }
    var canAccessActiveDestination: Bool { isActiveDestinationOpen && active.destinationEnabled }
    var openedContextIDs: Set<String> { Set(stores.filter(\.destinationEnabled).map(\.contextID)) }
    var recoverySpaces: [String] { Array(Set(retired.flatMap(\.spaces))).sorted() }
    private var retiredStores: [String: HerdrStore] = [:]
    private var knownSpaces: [String: Set<String>] = [:]
    private var savedMachines: [HerdrMachineProfile] = []
    private var requiresFreshCatalog = false
    private var restorationKey: String?
    private var restorationDefaults: UserDefaults?
    private var restorationFailed = false
    private var hasWindowClaim = false
    private static var claimedWindows: Set<String> = []
    private(set) var isRunning = false
    private var subscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var catalogSubscription: AnyCancellable?
    private var navigation = UUID()
    private var previousSelection: (space: String?, tab: String?, pane: String?)?
    @Published private(set) var terminalRequestID = UUID()
    private var terminalRequest: (context: String, pane: String)?
    private var acknowledgeTask: Task<Void, Never>?
    var onOpenTerminal: () -> Void = {}
    var onConnectionsChanged: () -> Void = {}
    var isTerminalVisible: () -> Bool = { true }
    private let notifier: HerdrNotifier
    private let pool: HerdrMetadataPool?
    let windowID = UUID()
    weak var nativeWindow: NSWindow?

    /// SceneStorage supplies the system-restored identity. After an explicit last-window
    /// close, use the last record once; additional new windows receive independent records.
    @discardableResult
    func restoreWindow(_ preferred: String, defaults: UserDefaults = .standard) -> String {
        if let restorationKey { return restorationKey }
        let lastKey = "HerdrConnectionsLastWindow"
        let candidate = preferred.isEmpty && Self.claimedWindows.isEmpty ? defaults.string(forKey: lastKey) : preferred
        let key = candidate.flatMap { !$0.isEmpty && !Self.claimedWindows.contains($0) ? $0 : nil }
            ?? UUID().uuidString
        Self.claimedWindows.insert(key)
        hasWindowClaim = true
        restorationKey = key
        requiresFreshCatalog = true
        restorationDefaults = defaults
        defaults.set(key, forKey: lastKey)
        let storageKey = "HerdrConnectionsWindow.\(key)"
        if let data = defaults.data(forKey: storageKey) {
            guard let state = try? JSONDecoder().decode(HerdrConnectionWindowState.self, from: data),
                  state.version == 1, state.root == HerdrStore.sessionRoot.standardizedFileURL.path,
                  (state.opened + state.retired).allSatisfy({ descriptor in
                      HerdrSessionName.isValid(descriptor.session)
                          && descriptor.spaces.allSatisfy { $0.hasPrefix(descriptor.id + "|") }
                  }), Set(state.opened.map(\.id)).count == state.opened.count,
                  state.selected.map({ selected in state.opened.contains { $0.id == selected } }) ?? true else {
                stores = []
                active.setDestinationEnabled(false, reason: "Window connections could not be restored.")
                lastLocal = nil
                restorationFailed = true
                catalogError = "Saved window connections could not be restored. No connections were opened; the saved record was preserved."
                return key
            }
            for descriptor in state.opened + state.retired {
                knownSpaces[descriptor.id, default: []].formUnion(descriptor.spaces)
            }
            stores = state.opened.map { makeStore($0) }
            retired = state.retired
            if let selected = state.selected, let store = stores.first(where: { $0.contextID == selected }) {
                active = store
            } else if state.selected != nil, let first = stores.first {
                active = first
            } else if let descriptor = state.retired.last {
                active = makeStore(descriptor)
                retiredStores[active.contextID] = active
                active.setDestinationEnabled(false, reason: "Connection closed in this window.")
            } else {
                active.setDestinationEnabled(false, reason: "No connections are open in this window.")
            }
            lastLocal = stores.first { $0.machine == nil }
        }
        persistWindow()
        return key
    }

    private func makeStore(_ descriptor: HerdrWindowConnection) -> HerdrStore {
        let store = HerdrStore()
        store.requiresSurfaceForInput = true
        store.setPresentationActive(false)
        if let machine = descriptor.machine {
            store.connect(to: machine, startImmediately: false)
            store.setDestinationEnabled(false, reason: "Checking saved SSH profile…")
        } else {
            store.connect(to: descriptor.session, remember: false, startImmediately: false)
        }
        return store
    }

    func configureInitialSession(_ name: String) {
        guard !isRunning, HerdrSessionName.isValid(name) else { return }
        let store = makeStore(HerdrWindowConnection(session: name))
        stores = [store]
        active = store
        lastLocal = store
        persistWindow()
    }

    private func persistWindow() {
        guard hasWindowClaim, !restorationFailed, let restorationKey, let defaults = restorationDefaults else { return }
        let state = HerdrConnectionWindowState(root: HerdrStore.sessionRoot.standardizedFileURL.path,
            opened: stores.map(descriptor), retired: retired,
            selected: isActiveDestinationOpen ? active.contextID : nil)
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: "HerdrConnectionsWindow.\(restorationKey)")
        }
    }

    private func descriptor(_ store: HerdrStore) -> HerdrWindowConnection {
        var value = HerdrWindowConnection(store)
        knownSpaces[value.id, default: []].formUnion(value.spaces)
        value.spaces = Array(knownSpaces[value.id] ?? []).sorted()
        return value
    }

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
        if let restorationKey {
            Self.claimedWindows.insert(restorationKey)
            hasWindowClaim = true
        }
        isRunning = true
        if catalogSubscription == nil, let pool {
            catalogSubscription = pool.profiles.sink { [weak self] profiles in
                guard let self, !requiresFreshCatalog else { return }
                if let profiles { applyCatalog(profiles) }
            }
        }
        for store in stores {
            attachMetadata(store)
            observe(store)
            store.start()
        }
        active.setPresentationActive(isActiveDestinationOpen)
        notifier.register(windowID, window: { [weak self] in self?.nativeWindow },
                          watched: { [weak self] in
            guard let self, nativeWindow?.isKeyWindow == true, active.inputReady, isTerminalVisible(),
                  let pane = active.selectedPaneID, active.surface?.focusedPaneID == pane else { return nil }
            return (active.contextID, pane)
        }, open: { [weak self] context, pane in self?.open(context: context, pane: pane) ?? false })
    }

    func stop() {
        persistWindow()
        if hasWindowClaim, let restorationKey {
            Self.claimedWindows.remove(restorationKey)
            hasWindowClaim = false
            if Self.claimedWindows.isEmpty {
                restorationDefaults?.set(restorationKey, forKey: "HerdrConnectionsLastWindow")
            }
        }
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
        let key = ObjectIdentifier(store)
        guard subscriptions[key] == nil else { return }
        subscriptions[key] = store.snapshotPublisher.sink { [weak self, weak store] snapshot in
            guard let self, let store else { return }
            if self.pool == nil { notifier.process(snapshot, selectedPaneID: nil, contextID: store.contextID) }
            self.persistWindow()
        }
    }

    func refresh(_ machines: [HerdrMachineProfile]) {
        guard isRunning else { return }
        requiresFreshCatalog = false
        if let pool { pool.profiles.send(machines) }
        else { applyCatalog(machines) }
    }

    private func applyCatalog(_ machines: [HerdrMachineProfile]) {
        guard isRunning else { return }
        if !restorationFailed { catalogError = nil }
        let enabled = machines.filter(\.enabled)
        guard enabled.allSatisfy({ HerdrSessionName.isValid($0.session) }) else {
            catalogError = "A saved host has an invalid Herdr session. Current connections were kept unchanged."
            return
        }
        savedMachines = machines
        for store in stores where store.machine != nil {
            guard let profile = enabled.first(where: { $0.id == store.machine?.id }),
                  profile.target == store.machine?.target, profile.session == store.sessionName else {
                remove(store)
                continue
            }
            store.updateProfile(profile)
            if !store.destinationEnabled {
                store.setDestinationEnabled(true, startImmediately: false)
                attachMetadata(store)
                store.start()
            }
            store.metadataSource?.updateProfile(profile)
        }
        persistWindow()
    }

    /// Releases only this window's lease. The archived active store retains editor identity,
    /// but cannot send input, actions, or notifications and is never redirected to Local.
    func remove(_ store: HerdrStore) {
        guard stores.contains(where: { $0 === store }) else { return }
        var descriptor = descriptor(store)
        descriptor.spaces = Array(Set(descriptor.spaces + (retired.first { $0.id == descriptor.id }?.spaces ?? []))).sorted()
        retired.removeAll { $0.id == descriptor.id }
        retired.append(descriptor)
        retiredStores[store.contextID] = store
        navigation = UUID()
        terminalRequest = nil
        terminalRequestID = UUID()
        acknowledgeTask?.cancel()
        previous = nil
        previousSelection = nil
        store.setPresentationActive(false)
        store.setDestinationEnabled(false, reason: "Connection closed in this window. Open it again in Connections.")
        if let source = store.metadataSource { pool?.release(source) }
        store.metadataSource = nil
        subscriptions.removeValue(forKey: ObjectIdentifier(store))
        stores.removeAll { $0 === store }
        onConnectionsChanged()
        if lastLocal === store { lastLocal = stores.first { $0.machine == nil } }
        persistWindow()
    }

    func openMachine(_ profile: HerdrMachineProfile) {
        guard isRunning, let current = savedMachines.first(where: { $0.id == profile.id }),
              current == profile, current.enabled else { return }
        if let store = stores.first(where: { $0.machine?.id == profile.id }) { select(store); return }
        open(HerdrWindowConnection(session: profile.session, machine: profile))
    }

    private func open(_ descriptor: HerdrWindowConnection) {
        if restorationFailed, let restorationKey, let defaults = restorationDefaults {
            // An explicit Open starts a fresh record, preserving the unreadable original.
            defaults.set(defaults.data(forKey: "HerdrConnectionsWindow.\(restorationKey)"),
                         forKey: "HerdrConnectionsWindowBackup.\(restorationKey)")
            restorationFailed = false
            catalogError = nil
        }
        let store = retiredStores.removeValue(forKey: descriptor.id) ?? makeStore(descriptor)
        if let profile = descriptor.machine { store.updateProfile(profile) }
        store.setDestinationEnabled(true, startImmediately: false)
        retired.removeAll { $0.id == descriptor.id }
        stores.append(store)
        onConnectionsChanged()
        attachMetadata(store)
        observe(store)
        select(store)
    }

    func reportCatalogError(_ error: Error) { catalogError = error.localizedDescription }

    func select(_ store: HerdrStore, workspaceID: String? = nil) {
        guard stores.contains(where: { $0 === store }), store.destinationEnabled else { return }
        terminalRequest = nil
        navigation = UUID()
        if store !== active || (workspaceID != nil && workspaceID != active.selectedWorkspaceID) {
            previous = canAccessActiveDestination ? active : nil
            previousSelection = previous.map { ($0.selectedWorkspaceID, $0.selectedTabID, $0.selectedPaneID) }
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
        persistWindow()
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
        guard HerdrSessionName.isValid(name) else {
            sessionSelectionError = "Use 1–64 letters, numbers, dots, hyphens, or underscores"
            return
        }
        sessionSelectionError = nil
        if let store = stores.first(where: { $0.machine == nil && $0.sessionName == name }) {
            select(store)
            return
        }
        open(HerdrWindowConnection(session: name))
    }

    func createSpace(on store: HerdrStore, cwd: String? = nil, label: String? = nil) {
        guard stores.contains(where: { $0 === store }), store.destinationEnabled else { return }
        let intent = navigation
        let previousContext = (active.contextID, active.selectedWorkspaceID, active.selectedTabID, active.selectedPaneID)
        store.createWorkspace(cwd: cwd, label: label, selectOnOpen: false) { [weak self, weak store] id in
            guard let self, let store, navigation == intent,
                  active.contextID == previousContext.0, active.selectedWorkspaceID == previousContext.1,
                  active.selectedTabID == previousContext.2, active.selectedPaneID == previousContext.3 else { return }
            select(store, workspaceID: id)
        }
    }

    /// The window's navigation intent includes switches away and back to the same server.
    /// Store selection alone cannot distinguish that from uninterrupted terminal viewing.
    @discardableResult
    func moveTab(_ tabID: String, toWorkspace workspaceID: String?, on store: HerdrStore,
                 shouldFollow: @escaping () -> Bool = { true }) -> Bool {
        guard active === store else { return false }
        let intent = navigation
        return store.moveTab(tabID, toWorkspace: workspaceID, shouldFollow: { [weak self, weak store] in
            guard let self, let store else { return false }
            return navigation == intent && active === store && shouldFollow()
        }, onFollow: { [weak self, weak store] pane in
            guard let self, let store, active === store else { return }
            requestTerminal(context: store.contextID, pane: pane.paneID)
        })
    }

    private func requestTerminal(context: String, pane: String) {
        terminalRequest = (context, pane)
        terminalRequestID = UUID()
        onOpenTerminal()
        acknowledgeVisiblePane()
    }

    private func open(context: String, pane: String) -> Bool {
        guard let store = stores.first(where: { $0.contextID == context }),
              let target = store.snapshot?.panes.first(where: { $0.paneID == pane }) else { return false }
        nativeWindow?.makeKeyAndOrderFront(nil)
        select(store, workspaceID: target.workspaceID)
        store.select(tabID: target.tabID)
        store.select(paneID: pane)
        requestTerminal(context: context, pane: pane)
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
    @ObservedObject var spaceDrag: SpaceDragModel
    @ObservedObject var tabDrag: TabDragModel
    let active: Bool
    let grouped: Bool
    var manage: () -> Void = {}
    var remove: () -> Void = {}
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
                    Menu {
                        Button("Connections…", action: manage)
                        Button("Remove from This Window", systemImage: "xmark", action: remove)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Connection actions")
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
                    .onDrag { spaceDrag.begin(space.workspaceID, store: store) }
                    .modifier(SpaceDropModifier(store: store, spaces: spaceDrag, tabs: tabDrag, workspaceID: space.workspaceID))
                    .help(tabDrag.draggedTerminalTab.flatMap { store.tabSpaceMoveRefusal($0, to: space.workspaceID) }
                          ?? "Drag to reorder Spaces, or drop a terminal tab to move it here")
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
                if tabDrag.isDraggingTerminalTab,
                   tabDrag.spaceConnection?.validStore === store {
                    Label("Drop terminal tab here for a new Space", systemImage: "plus.square.dashed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .modifier(SpaceDropModifier(store: store, spaces: spaceDrag, tabs: tabDrag, workspaceID: nil))
                        .help(tabDrag.draggedTerminalTab.flatMap { store.tabSpaceMoveRefusal($0, to: nil) }
                              ?? "Move a single-pane terminal tab into a new Space")
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
