import Foundation

/// The declarative query sent by Herdr; unknown rules reject the whole query rather than
/// partially filtering the sidebar. Limits follow Herdr 0.9.3's agent view validator.
struct HerdrAgentView: Decodable, Equatable, Sendable {
    let source: String
    let label: String?
    let filter: HerdrAgentFilter?
    let sort: [HerdrAgentSort]

    var title: String { label ?? "Filtered" }

    private enum CodingKeys: String, CodingKey { case source, label, filter, sort }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(String.self, forKey: .source)
        label = try values.decodeIfPresent(String.self, forKey: .label)
        filter = try values.decodeIfPresent(HerdrAgentFilter.self, forKey: .filter)
        sort = try values.decodeIfPresent([HerdrAgentSort].self, forKey: .sort) ?? []
        var nodes = 0
        guard !source.isEmpty, source.count <= 120,
              source.utf8.allSatisfy({ Self.identifierBytes.contains($0) }),
              label.map({ !$0.isEmpty && $0.count <= 32 && !$0.contains(where: { $0.isNewline }) }) ?? true,
              sort.count <= 8, filter?.valid(depth: 1, nodes: &nodes) ?? true else {
            throw AgentViewDecodingError.invalidQuery
        }
    }

    private static let identifierBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:._-".utf8)
}

private enum AgentViewDecodingError: Error { case invalidQuery }

enum HerdrAgentField: Decodable, Equatable, Sendable {
    case builtin(String)
    case token(String)

    static let filterNames: Set<String> = ["status", "workspace_id", "tab_id", "pane_id", "agent", "seen", "state_change_seq"]
    static let sortNames: Set<String> = ["workspace_order", "tab_order", "pane_order", "attention", "status", "agent", "seen", "state_change_seq"]

    private enum CodingKeys: String, CodingKey { case token }

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard Self.filterNames.union(Self.sortNames).contains(name) else { throw AgentViewDecodingError.invalidQuery }
            self = .builtin(name)
        } else {
            let name = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .token)
            guard !name.isEmpty, name.utf8.count <= 32,
                  name.utf8.allSatisfy({ Self.tokenBytes.contains($0) }) else { throw AgentViewDecodingError.invalidQuery }
            self = .token(name)
        }
    }

    private static let tokenBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".utf8)

    var canFilter: Bool {
        if case .builtin(let name) = self { return Self.filterNames.contains(name) }
        return true
    }

    var canSort: Bool {
        if case .builtin(let name) = self { return Self.sortNames.contains(name) }
        return true
    }
}

enum HerdrAgentValue: Decodable, Equatable, Sendable {
    case string(String), bool(Bool), number(UInt64), context(String)

    private enum CodingKeys: String, CodingKey { case context }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(UInt64.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else {
            let name = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .context)
            guard ["current_workspace_id", "current_tab_id"].contains(name) else { throw AgentViewDecodingError.invalidQuery }
            self = .context(name)
        }
    }

    func valid(for field: HerdrAgentField) -> Bool {
        switch (field, self) {
        case (.builtin("workspace_id"), .context("current_workspace_id")),
             (.builtin("tab_id"), .context("current_tab_id")),
             (.builtin("seen"), .bool), (.builtin("state_change_seq"), .number): return true
        case (.builtin("status"), .string(let value)): return ["idle", "working", "blocked", "done", "unknown"].contains(value)
        case (.builtin(let name), .string): return ["workspace_id", "tab_id", "pane_id", "agent"].contains(name)
        case (.token, .string): return true
        default: return false
        }
    }

    func resolved(workspaceID: String?, tabID: String?) -> HerdrAgentValue? {
        switch self {
        case .context("current_workspace_id"): return workspaceID.map(Self.string)
        case .context("current_tab_id"): return tabID.map(Self.string)
        case .context: return nil
        default: return self
        }
    }

    func compare(to other: HerdrAgentValue) -> ComparisonResult {
        switch (self, other) {
        case (.string(let lhs), .string(let rhs)):
            return lhs.utf8.elementsEqual(rhs.utf8) ? .orderedSame : (lhs.utf8.lexicographicallyPrecedes(rhs.utf8) ? .orderedAscending : .orderedDescending)
        case (.number(let lhs), .number(let rhs)): return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.bool(let lhs), .bool(let rhs)): return lhs == rhs ? .orderedSame : (!lhs ? .orderedAscending : .orderedDescending)
        default: return .orderedSame
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.string(let lhs), .string(let rhs)), (.context(let lhs), .context(let rhs)): return lhs.utf8.elementsEqual(rhs.utf8)
        case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
        case (.number(let lhs), .number(let rhs)): return lhs == rhs
        default: return false
        }
    }
}

indirect enum HerdrAgentFilter: Decodable, Equatable, Sendable {
    case all([Self]), any([Self]), not(Self)
    case equal(HerdrAgentField, HerdrAgentValue), oneOf(HerdrAgentField, [HerdrAgentValue]), exists(HerdrAgentField)

    private enum CodingKeys: String, CodingKey { case op, filters, filter, field, value, values }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .op) {
        case "all": self = .all(try values.decode([Self].self, forKey: .filters))
        case "any": self = .any(try values.decode([Self].self, forKey: .filters))
        case "not": self = .not(try values.decode(Self.self, forKey: .filter))
        case "eq": self = .equal(try values.decode(HerdrAgentField.self, forKey: .field), try values.decode(HerdrAgentValue.self, forKey: .value))
        case "in": self = .oneOf(try values.decode(HerdrAgentField.self, forKey: .field), try values.decode([HerdrAgentValue].self, forKey: .values))
        case "exists": self = .exists(try values.decode(HerdrAgentField.self, forKey: .field))
        default: throw AgentViewDecodingError.invalidQuery
        }
    }

    func valid(depth: Int, nodes: inout Int) -> Bool {
        nodes += 1
        guard depth <= 8, nodes <= 64 else { return false }
        switch self {
        case .all(let filters), .any(let filters):
            return !filters.isEmpty && filters.allSatisfy { $0.valid(depth: depth + 1, nodes: &nodes) }
        case .not(let filter): return filter.valid(depth: depth + 1, nodes: &nodes)
        case .equal(let field, let value): return field.canFilter && value.valid(for: field)
        case .oneOf(let field, let values):
            return field.canFilter && !values.isEmpty && values.count <= 32 && values.allSatisfy { $0.valid(for: field) }
        case .exists(let field): return field.canFilter
        }
    }

    func matches(_ row: HerdrAgentViewRow, workspaceID: String?, tabID: String?) -> Bool {
        switch self {
        case .all(let filters): return filters.allSatisfy { $0.matches(row, workspaceID: workspaceID, tabID: tabID) }
        case .any(let filters): return filters.contains { $0.matches(row, workspaceID: workspaceID, tabID: tabID) }
        case .not(let filter): return !filter.matches(row, workspaceID: workspaceID, tabID: tabID)
        case .equal(let field, let value): return row.value(for: field) == value.resolved(workspaceID: workspaceID, tabID: tabID)
        case .oneOf(let field, let values):
            return values.contains { row.value(for: field) == $0.resolved(workspaceID: workspaceID, tabID: tabID) }
        case .exists(let field): return row.value(for: field) != nil
        }
    }
}

struct HerdrAgentSort: Decodable, Equatable, Sendable {
    let field: HerdrAgentField
    let descending: Bool

    private enum CodingKeys: String, CodingKey { case field, order }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        field = try values.decode(HerdrAgentField.self, forKey: .field)
        let order = try values.decodeIfPresent(String.self, forKey: .order) ?? "asc"
        guard field.canSort, ["asc", "desc"].contains(order) else { throw AgentViewDecodingError.invalidQuery }
        descending = order == "desc"
    }

    func compare(_ lhs: HerdrAgentViewRow, _ rhs: HerdrAgentViewRow) -> ComparisonResult {
        switch (lhs.value(for: field), rhs.value(for: field)) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let lhs?, let rhs?):
            let comparison = lhs.compare(to: rhs)
            if !descending || comparison == .orderedSame { return comparison }
            return comparison == .orderedAscending ? .orderedDescending : .orderedAscending
        }
    }
}

struct HerdrAgentViewRow {
    let agent: HerdrAgent
    let seen: Bool
    let workspaceOrder: UInt64?
    let tabOrder: UInt64?

    func value(for field: HerdrAgentField) -> HerdrAgentValue? {
        if case .token(let name) = field { return agent.tokens?[name].map(HerdrAgentValue.string) }
        guard case .builtin(let name) = field else { return nil }
        switch name {
        case "status": return .string(agent.agentStatus ?? "unknown")
        case "workspace_id": return agent.workspaceID.map(HerdrAgentValue.string)
        case "tab_id": return agent.tabID.map(HerdrAgentValue.string)
        case "pane_id": return .string(agent.paneID)
        case "agent": return agent.agent.map(HerdrAgentValue.string)
        case "seen": return .bool(seen)
        case "state_change_seq": return .number(agent.stateChangeSeq)
        case "workspace_order": return workspaceOrder.map(HerdrAgentValue.number)
        case "tab_order": return tabOrder.map(HerdrAgentValue.number)
        case "pane_order":
            guard let workspace = agent.workspaceID, agent.paneID.hasPrefix(workspace + ":p") else { return nil }
            return Self.publicNumber(String(agent.paneID.dropFirst(workspace.count + 2))).map(HerdrAgentValue.number)
        case "attention":
            return .number(["blocked": 4, "done": 3, "working": 2, "idle": 1][agent.agentStatus ?? "unknown"] ?? 0)
        default: return nil
        }
    }

    /// Herdr's IDs use bijective base 32, rather than decimal pane numbers.
    static func publicNumber(_ suffix: String) -> UInt64? {
        let alphabet = Array("123456789ABCDEFGHJKMNPQRSTVWXYZ0")
        guard !suffix.isEmpty else { return nil }
        var value: UInt64 = 0
        for character in suffix {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            let product = value.multipliedReportingOverflow(by: 32)
            let sum = product.partialValue.addingReportingOverflow(UInt64(digit + 1))
            guard !product.overflow, !sum.overflow else { return nil }
            value = sum.partialValue
        }
        return value
    }
}

/// Only the agent facts needed from shell.snapshot.v1. The other snapshot fields remain
/// owned by the JSON connection. Endpoint metadata is encoded as arrays of string pairs.
struct HerdrAgentSnapshot: Decodable, Equatable, Sendable {
    struct Workspace: Decodable, Equatable, Sendable {
        let workspaceID: String
        enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
    }
    struct Tab: Decodable, Equatable, Sendable {
        let tabID: String
        let number: UInt64
        enum CodingKeys: String, CodingKey { case tabID = "tab_id", number }
    }

    let bootID: String
    let revision: UInt64
    let agentViewLabel: String?
    let workspaces: [Workspace]
    let tabs: [Tab]
    let agents: [HerdrAgent]

    enum CodingKeys: String, CodingKey {
        case bootID = "boot_id", revision, workspaces, tabs, agents
        case agentViewLabel = "agent_view_label"
    }
}

struct HerdrAgentViewMessage: Decodable, Sendable {
    let bootID: String
    let revision: UInt64
    let view: HerdrAgentView?
    let unavailable: Bool

    private enum CodingKeys: String, CodingKey { case bootID = "boot_id", revision, view }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bootID = try values.decode(String.self, forKey: .bootID)
        revision = try values.decode(UInt64.self, forKey: .revision)
        if try values.decodeNil(forKey: .view) { view = nil; unavailable = false }
        else {
            view = try? values.decode(HerdrAgentView.self, forKey: .view)
            unavailable = view == nil
        }
    }
}

struct HerdrAgentCompletions: Decodable, Sendable {
    let bootID: String
    let revision: UInt64
    let completions: [String: UInt64]
    enum CodingKeys: String, CodingKey { case bootID = "boot_id", revision, completions }
}

struct HerdrAgentProjection: Sendable {
    let snapshot: HerdrAgentSnapshot
    let view: HerdrAgentView?
    let unavailable: Bool
    let completions: [String: UInt64]?
}

/// Companions precede their snapshot on Herdr's control stream. Never carry a query or
/// completion map into another revision, boot, or connection.
struct HerdrAgentProjectionDecoder {
    private var snapshot: HerdrAgentSnapshot?
    private var currentView: HerdrAgentViewMessage?
    private var currentCompletions: [String: UInt64]?
    private var pendingView: HerdrAgentViewMessage?
    private var pendingCompletions: HerdrAgentCompletions?

    mutating func receive(kind: String, data: Data) -> HerdrAgentProjection? {
        let decoder = JSONDecoder()
        switch kind {
        case "endpoint.agent-view.v1":
            if let message = try? decoder.decode(HerdrAgentViewMessage.self, from: data),
               snapshot.map({ $0.bootID != message.bootID || $0.revision <= message.revision }) ?? true,
               pendingView.map({ $0.bootID != message.bootID || $0.revision < message.revision }) ?? true {
                pendingView = message
                if let snapshot, snapshot.bootID == message.bootID, snapshot.revision == message.revision {
                    currentView = message
                    pendingView = nil
                    return projection(for: snapshot)
                }
            }
        case "endpoint.agent-completions.v1":
            if let message = try? decoder.decode(HerdrAgentCompletions.self, from: data),
               snapshot.map({ $0.bootID != message.bootID || $0.revision <= message.revision }) ?? true,
               pendingCompletions.map({ $0.bootID != message.bootID || $0.revision < message.revision }) ?? true {
                pendingCompletions = message
                if let snapshot, snapshot.bootID == message.bootID, snapshot.revision == message.revision {
                    currentCompletions = message.completions
                    pendingCompletions = nil
                    return projection(for: snapshot)
                }
            }
        case "shell.snapshot.v1":
            guard let next = try? decoder.decode(HerdrAgentSnapshot.self, from: data),
                  Set(next.agents.map(\.paneID)).count == next.agents.count,
                  snapshot.map({ $0.bootID != next.bootID || $0.revision < next.revision }) ?? true else { return nil }
            snapshot = next
            let view = pendingView.flatMap { $0.bootID == next.bootID && $0.revision == next.revision ? $0 : nil }
            let completions = pendingCompletions.flatMap { $0.bootID == next.bootID && $0.revision == next.revision ? $0.completions : nil }
            pendingView = pendingView.flatMap { $0.bootID == next.bootID && $0.revision > next.revision ? $0 : nil }
            pendingCompletions = pendingCompletions.flatMap { $0.bootID == next.bootID && $0.revision > next.revision ? $0 : nil }
            currentView = view
            currentCompletions = completions
            return projection(for: next)
        default: break
        }
        return nil
    }

    private func projection(for snapshot: HerdrAgentSnapshot) -> HerdrAgentProjection {
        HerdrAgentProjection(snapshot: snapshot, view: currentView?.view,
                             unavailable: currentView?.unavailable ?? (snapshot.agentViewLabel != nil),
                             completions: currentCompletions)
    }
}

/// Published only when agent facts or the query change, not when terminal frames arrive.
struct HerdrAgentViewState: Equatable, Sendable {
    let view: HerdrAgentView?
    let label: String?
    let unavailable: Bool
    let agents: [HerdrAgent]
    let seenPaneIDs: Set<String>
    let workspaces: [HerdrAgentSnapshot.Workspace]
    let tabs: [HerdrAgentSnapshot.Tab]

    func agents(workspaceID: String?, tabID: String?, spaceOnly: Bool, followView: Bool, prioritySort: Bool = false) -> [HerdrAgent] {
        var rows = agents.map { agent in
            HerdrAgentViewRow(agent: agent, seen: seenPaneIDs.contains(agent.paneID),
                              workspaceOrder: workspaces.firstIndex { $0.workspaceID == agent.workspaceID }.map(UInt64.init),
                              tabOrder: tabs.first { $0.tabID == agent.tabID }?.number)
        }
        if followView, let view {
            if let filter = view.filter { rows.removeAll { !filter.matches($0, workspaceID: workspaceID, tabID: tabID) } }
            // Preserve input order for equal keys, independently of Swift's sorting algorithm.
            rows = rows.enumerated().sorted { lhs, rhs in
                if view.sort.isEmpty, prioritySort {
                    let left = lhs.element.value(for: .builtin("attention"))
                    let right = rhs.element.value(for: .builtin("attention"))
                    if let left, let right, left != right { return left.compare(to: right) == .orderedDescending }
                    if lhs.element.agent.stateChangeSeq != rhs.element.agent.stateChangeSeq {
                        return lhs.element.agent.stateChangeSeq > rhs.element.agent.stateChangeSeq
                    }
                }
                for sort in view.sort {
                    let result = sort.compare(lhs.element, rhs.element)
                    if result != .orderedSame { return result == .orderedAscending }
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
        return rows.filter { !spaceOnly || $0.agent.workspaceID == workspaceID }.map(\.agent)
    }
}

/// Completion/seen state belongs to this client. A server completion companion is
/// authoritative; observing working→idle is the fallback for older servers.
struct HerdrAgentPresentation {
    private var projection: HerdrAgentProjection?
    private var acknowledged: [String: UInt64] = [:]
    private var completed: [String: UInt64] = [:]
    private var working: Set<String> = []

    mutating func receive(_ next: HerdrAgentProjection) -> HerdrAgentViewState {
        if projection?.snapshot.bootID != next.snapshot.bootID {
            acknowledged = Dictionary(uniqueKeysWithValues: next.snapshot.agents.map { ($0.paneID, $0.stateChangeSeq) })
            completed = [:]
            working = []
        }
        projection = next
        let panes = Set(next.snapshot.agents.map(\.paneID))
        acknowledged = acknowledged.filter { panes.contains($0.key) }
        completed = completed.filter { panes.contains($0.key) }
        working.formIntersection(panes)
        for agent in next.snapshot.agents {
            switch agent.agentStatus {
            case "working": working.insert(agent.paneID); completed[agent.paneID] = nil
            case "blocked": completed[agent.paneID] = nil
            case "idle", "done":
                let observedWork = working.remove(agent.paneID) != nil
                let didComplete = next.completions.map { $0[agent.paneID] == agent.stateChangeSeq }
                    ?? (observedWork || completed[agent.paneID] == agent.stateChangeSeq)
                completed[agent.paneID] = didComplete ? agent.stateChangeSeq : nil
            default: working.remove(agent.paneID); completed[agent.paneID] = nil
            }
        }
        return state()
    }

    /// Called after a visible surface is drawn in this window, not merely after focus is sent.
    mutating func acknowledge(_ surface: HerdrSurface) -> HerdrAgentViewState? {
        guard let projection, projection.snapshot.bootID == surface.bootID,
              projection.snapshot.revision == surface.projectionRevision else { return nil }
        var changed = false
        for agent in projection.snapshot.agents where surface.paneIDs.contains(agent.paneID) {
            if (acknowledged[agent.paneID] ?? 0) < agent.stateChangeSeq {
                acknowledged[agent.paneID] = agent.stateChangeSeq
                changed = true
            }
        }
        return changed ? state() : nil
    }

    private func state() -> HerdrAgentViewState {
        let projection = projection!
        var seen: Set<String> = []
        let agents = projection.snapshot.agents.map { raw in
            var agent = raw
            let hasSeen = completed[agent.paneID].map { (acknowledged[agent.paneID] ?? 0) >= $0 } ?? true
            if hasSeen { seen.insert(agent.paneID) }
            if agent.agentStatus == "idle" || agent.agentStatus == "done" { agent.agentStatus = hasSeen ? "idle" : "done" }
            return agent
        }
        return HerdrAgentViewState(view: projection.view, label: projection.view?.title ?? projection.snapshot.agentViewLabel,
                                   unavailable: projection.unavailable, agents: agents, seenPaneIDs: seen,
                                   workspaces: projection.snapshot.workspaces, tabs: projection.snapshot.tabs)
    }
}
