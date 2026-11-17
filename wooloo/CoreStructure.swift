import Foundation

// wooloo's Spaces, tabs and splits for a herdr-core session (docs/proposals/herdr-core-backend.md,
// §5 and decision D2). Core keeps terminals, not layout, so wooloo keeps its arrangement in a
// document of its own in the core, `wooloo`, written only with compare-and-set on its version.
// The terminals Core reports are the truth for what exists; the document is the truth for how
// it is arranged; the `wooloo.space` label is a hint for terminals no tab holds.

struct CoreStructure: Equatable, Sendable {
    static let documentName = "wooloo"
    static let schema = 1
    static let spaceLabel = "wooloo.space"
    static let unfiledID = "unfiled"

    enum Direction: String, Codable, Sendable {
        /// Side by side: the second pane is right of the first.
        case right
        /// Stacked: the second pane is below the first.
        case down
    }

    indirect enum Node: Equatable, Sendable {
        case terminal(String)
        case split(Direction, ratio: Double, first: Node, second: Node)

        var terminals: [String] {
            switch self {
            case .terminal(let address): return [address]
            case let .split(_, _, first, second): return first.terminals + second.terminals
            }
        }

        /// This tree without terminals `keep` rejects; a split left with one side becomes that side.
        func filtered(_ keep: (String) -> Bool) -> Node? {
            switch self {
            case .terminal(let address): return keep(address) ? self : nil
            case let .split(direction, ratio, first, second):
                switch (first.filtered(keep), second.filtered(keep)) {
                case let (a?, b?): return .split(direction, ratio: ratio, first: a, second: b)
                case let (a?, nil): return a
                case let (nil, b?): return b
                case (nil, nil): return nil
                }
            }
        }

        /// Splits `target` in two, putting `new` on its `direction` side (right or below).
        func splitting(_ target: String, with new: String, direction: Direction, newFirst: Bool = false) -> Node {
            switch self {
            case .terminal(let address):
                guard address == target else { return self }
                return newFirst
                    ? .split(direction, ratio: 0.5, first: .terminal(new), second: self)
                    : .split(direction, ratio: 0.5, first: self, second: .terminal(new))
            case let .split(d, ratio, first, second):
                return .split(d, ratio: ratio, first: first.splitting(target, with: new, direction: direction, newFirst: newFirst),
                              second: second.splitting(target, with: new, direction: direction, newFirst: newFirst))
            }
        }

        /// This tree with the split at `path` (false: first side, true: second) set to `ratio`.
        func settingRatio(_ ratio: Double, at path: ArraySlice<Bool>) -> Node {
            guard case let .split(direction, current, first, second) = self else { return self }
            guard let step = path.first else {
                return .split(direction, ratio: min(max(ratio, 0.05), 0.95), first: first, second: second)
            }
            let rest = path.dropFirst()
            return step
                ? .split(direction, ratio: current, first: first, second: second.settingRatio(ratio, at: rest))
                : .split(direction, ratio: current, first: first.settingRatio(ratio, at: rest), second: second)
        }

        func swapping(_ a: String, _ b: String) -> Node {
            switch self {
            case .terminal(let address): return .terminal(address == a ? b : address == b ? a : address)
            case let .split(d, ratio, first, second):
                return .split(d, ratio: ratio, first: first.swapping(a, b), second: second.swapping(a, b))
            }
        }
    }

    struct Tab: Equatable, Sendable {
        var id: String
        var name: String?
        var root: Node
    }

    struct Space: Equatable, Sendable {
        var id: String
        var name: String
        var folder: String?
        var tabs: [Tab]
    }

    var spaces: [Space] = []

    var terminals: Set<String> { Set(spaces.flatMap { $0.tabs.flatMap(\.root.terminals) }) }

    func space(of terminal: String) -> Int? { spaces.firstIndex { $0.tabs.contains { $0.root.terminals.contains(terminal) } } }
    func tab(of terminal: String) -> (space: Int, tab: Int)? {
        for (s, space) in spaces.enumerated() {
            if let t = space.tabs.firstIndex(where: { $0.root.terminals.contains(terminal) }) { return (s, t) }
        }
        return nil
    }
    func tab(_ id: String) -> (space: Int, tab: Int)? {
        for (s, space) in spaces.enumerated() {
            if let t = space.tabs.firstIndex(where: { $0.id == id }) { return (s, t) }
        }
        return nil
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    // MARK: Reconciliation

    /// The arrangement of `terminals` (live, on this core): document entries whose terminal is
    /// gone are dropped, and live terminals no tab holds become tabs of the Space their
    /// `wooloo.space` label names, or of an Unfiled Space at the end.
    func reconciled(with terminals: [CoreTerminal]) -> CoreStructure {
        let live = terminals.filter { $0.state == "live" && !$0.address.contains("/") }
        let alive = Set(live.map(\.address))
        var result = CoreStructure()
        for space in spaces {
            var kept = space
            kept.tabs = space.tabs.compactMap { tab in
                tab.root.filtered(alive.contains).map { Tab(id: tab.id, name: tab.name, root: $0) }
            }
            if !kept.tabs.isEmpty { result.spaces.append(kept) }
        }
        let filed = result.terminals
        for terminal in live where !filed.contains(terminal.address) {
            let wanted = terminal.labels[Self.spaceLabel]
            let tab = Tab(id: "tab-\(terminal.address)", name: nil, root: .terminal(terminal.address))
            if let wanted, let index = result.spaces.firstIndex(where: { $0.id == wanted }) {
                result.spaces[index].tabs.append(tab)
            } else if let index = result.spaces.firstIndex(where: { $0.id == Self.unfiledID }) {
                result.spaces[index].tabs.append(tab)
            } else {
                result.spaces.append(Space(id: Self.unfiledID, name: "Unfiled", folder: nil, tabs: [tab]))
            }
        }
        return result
    }

    // MARK: Document

    /// Decodes the `wooloo` document; nil for a missing document, another schema or a broken
    /// one. Every field is checked, since any program in the core may write documents.
    static func decode(_ value: Any?) -> CoreStructure? {
        guard let object = value as? [String: Any], object["schema"] as? Int == schema,
              let spaces = object["spaces"] as? [[String: Any]] else { return nil }
        var result = CoreStructure()
        for space in spaces.prefix(500) {
            guard let id = space["id"] as? String, !id.isEmpty, id.count <= 128,
                  let name = space["name"] as? String, name.count <= 512,
                  let tabs = space["tabs"] as? [[String: Any]] else { continue }
            let folder = (space["folder"] as? String).flatMap { $0.hasPrefix("/") && $0.count <= 4096 ? $0 : nil }
            let decodedTabs = tabs.prefix(500).compactMap { tab -> Tab? in
                guard let id = tab["id"] as? String, !id.isEmpty, id.count <= 128,
                      let root = node(tab["root"], depth: 0) else { return nil }
                return Tab(id: id, name: (tab["name"] as? String).flatMap { $0.count <= 512 ? $0 : nil }, root: root)
            }
            result.spaces.append(Space(id: id, name: name, folder: folder, tabs: decodedTabs))
        }
        return result
    }

    private static func node(_ value: Any?, depth: Int) -> Node? {
        guard depth < 32, let object = value as? [String: Any] else { return nil }
        if let terminal = object["terminal"] as? String, !terminal.isEmpty, terminal.count <= 64 { return .terminal(terminal) }
        guard let raw = object["split"] as? String, let direction = Direction(rawValue: raw),
              let first = node(object["first"], depth: depth + 1),
              let second = node(object["second"], depth: depth + 1) else { return nil }
        let ratio = (object["ratio"] as? Double).map { min(max($0, 0.05), 0.95) } ?? 0.5
        return .split(direction, ratio: ratio, first: first, second: second)
    }

    /// The document to write, keeping top-level fields of `previous` this build does not know.
    func encoded(over previous: Any?) -> [String: Any] {
        var object = (previous as? [String: Any]) ?? [:]
        object["schema"] = Self.schema
        object["spaces"] = spaces.map { space -> [String: Any] in
            var value: [String: Any] = ["id": space.id, "name": space.name,
                                        "tabs": space.tabs.map { tab -> [String: Any] in
                                            var value: [String: Any] = ["id": tab.id, "root": Self.encode(tab.root)]
                                            if let name = tab.name { value["name"] = name }
                                            return value
                                        }]
            if let folder = space.folder { value["folder"] = folder }
            return value
        }
        return object
    }

    private static func encode(_ node: Node) -> [String: Any] {
        switch node {
        case .terminal(let address): return ["terminal": address]
        case let .split(direction, ratio, first, second):
            return ["split": direction.rawValue, "ratio": ratio, "first": encode(first), "second": encode(second)]
        }
    }
}

/// Lays out a pane tree in a grid of cells, with a one-cell border between the two sides of
/// each split, as Herdr draws its panes.
enum CoreLayout {
    struct Split: Equatable, Sendable {
        let direction: CoreStructure.Direction
        /// The border's column (right) or row (down).
        let position: Int
        let area: HerdrRect
        let path: [Bool]
    }

    static func panes(_ node: CoreStructure.Node, in area: HerdrRect) -> [(terminal: String, rect: HerdrRect)] {
        layout(node, in: area, path: []).panes
    }

    static func splits(_ node: CoreStructure.Node, in area: HerdrRect) -> [Split] {
        layout(node, in: area, path: []).splits
    }

    private static func layout(_ node: CoreStructure.Node, in area: HerdrRect, path: [Bool])
        -> (panes: [(terminal: String, rect: HerdrRect)], splits: [Split]) {
        switch node {
        case .terminal(let address): return ([(address, area)], [])
        case let .split(direction, ratio, first, second):
            let along = direction == .right ? area.width : area.height
            guard along >= 3 else { return layout(first, in: area, path: path + [false]) }
            let firstSize = min(max(Int((Double(along - 1) * ratio).rounded()), 1), along - 2)
            let a: HerdrRect, b: HerdrRect, position: Int
            if direction == .right {
                a = HerdrRect(x: area.x, y: area.y, width: firstSize, height: area.height)
                position = area.x + firstSize
                b = HerdrRect(x: position + 1, y: area.y, width: area.width - firstSize - 1, height: area.height)
            } else {
                a = HerdrRect(x: area.x, y: area.y, width: area.width, height: firstSize)
                position = area.y + firstSize
                b = HerdrRect(x: area.x, y: position + 1, width: area.width, height: area.height - firstSize - 1)
            }
            let left = layout(first, in: a, path: path + [false])
            let right = layout(second, in: b, path: path + [true])
            return (left.panes + right.panes,
                    [Split(direction: direction, position: position, area: area, path: path)] + left.splits + right.splits)
        }
    }
}
