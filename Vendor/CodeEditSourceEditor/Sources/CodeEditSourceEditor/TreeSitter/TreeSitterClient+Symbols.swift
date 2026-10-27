import Foundation
import SwiftTreeSitter

/// Immutable UTF-16 positions; no parser nodes escape the executor that owns the tree.
public struct SourceSymbol: Identifiable, Equatable, Sendable {
    public let name: String
    public let kind: String
    public let range: NSRange
    public let selectionRange: NSRange
    public let children: [SourceSymbol]
    public var id: Int { range.location }

    public init(name: String, kind: String, range: NSRange, selectionRange: NSRange,
                children: [SourceSymbol] = []) {
        self.name = name
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
    }
}

extension TreeSitterClient {
    /// Call on the main queue after edits have been delivered to the client. The source is an
    /// immutable snapshot belonging to the caller's revision; callers discard obsolete results.
    /// A nil result means parsing was cancelled, or this client has changed languages.
    public func querySymbols(source: String, languageID: String,
                             completion: @escaping @MainActor ([SourceSymbol]?) -> Void) {
        // execAsync may call onCancel after an operation has already enqueued its result.
        // Both paths deliver on main, so this gate guarantees one callback (also for continuations).
        var delivered = false
        let finish: @MainActor ([SourceSymbol]?) -> Void = { symbols in
            guard !delivered else { return }
            delivered = true
            completion(symbols)
        }
        let text = source as NSString
        let revision = symbolRevision
        executor.execAsync(priority: .access, operation: { [weak self] in
            guard let self, self.parsedSymbolRevision == revision, self.pendingEdits.value().isEmpty,
                  let state = self.state, state.primaryLayer.id.rawValue == languageID,
                  let root = state.layers.first?.tree?.rootNode,
                  root.range.length == text.length, !Task.isCancelled else {
                DispatchQueue.main.async { finish(nil) }
                return
            }
            let result = Self.collectSymbols(root: root, text: text, languageID: languageID)
            DispatchQueue.main.async { finish(result) }
        }, onCancel: { DispatchQueue.main.async { finish(nil) } })
    }

    private static func collectSymbols(root: Node, text: NSString, languageID: String) -> [SourceSymbol] {
        // Visit iteratively: unfinished files may contain deeply nested/error nodes.
        struct Entry {
            let node: Node
            let parent: Int?
            let depth: Int
        }
        struct Value {
            let node: Node
            let name: String
            let selection: NSRange
            let kind: String
            let parent: Int?
        }
        var stack = [Entry(node: root, parent: nil, depth: 0)]
        var values: [Value] = []
        while let entry = stack.popLast(), !Task.isCancelled {
            let node = entry.node
            let type = node.nodeType ?? ""
            var parent = entry.parent
            if let kind = symbolKind(type, languageID: languageID) {
                let nameNode = node.child(byFieldName: "name") ?? node.firstChild(where: {
                    ["simple_identifier", "type_identifier", "identifier"].contains($0.nodeType ?? "")
                })
                let special = type == "init_declaration" ? "init" : type == "deinit_declaration" ? "deinit" : nil
                let selection: NSRange?
                if let special {
                    selection = node.firstChild(where: { $0.nodeType == special })?.range
                } else { selection = nameNode?.range }
                if let selection, selection.length > 0, NSMaxRange(selection) <= text.length {
                    parent = values.count
                    values.append(Value(node: node, name: special ?? text.substring(with: selection),
                                        selection: selection, kind: kind, parent: entry.parent))
                }
            }
            // No symbols live inside comments/strings. Bounded traversal also protects against
            // adversarial nesting while retaining useful top-level declarations in broken files.
            if entry.depth < 256 && !type.contains("comment") && !type.contains("string") {
                for index in (0..<node.namedChildCount).reversed() {
                    if let child = node.namedChild(at: index) {
                        stack.append(Entry(node: child, parent: parent, depth: entry.depth + 1))
                    }
                }
            }
        }
        guard !Task.isCancelled else { return [] }
        var built: [Int: [SourceSymbol]] = [:]
        var roots: [SourceSymbol] = []
        for index in values.indices.reversed() {
            let value = values[index]
            let symbol = SourceSymbol(name: value.name, kind: value.kind,
                                      range: value.node.range, selectionRange: value.selection,
                                      children: (built[index] ?? []).reversed())
            if let parent = value.parent { built[parent, default: []].append(symbol) }
            else { roots.append(symbol) }
        }
        return roots.reversed()
    }

    private static func symbolKind(_ type: String, languageID: String) -> String? {
        switch languageID {
        case "swift":
            switch type {
            case "class_declaration", "protocol_declaration", "typealias_declaration": return "type"
            case "function_declaration", "init_declaration", "deinit_declaration": return "function"
            default: return nil
            }
        case "javascript", "jsx", "typescript", "tsx":
            switch type {
            case "class_declaration", "interface_declaration", "type_alias_declaration", "enum_declaration": return "type"
            case "function_declaration", "generator_function_declaration", "method_definition", "method_signature": return "function"
            // Named arrow/function expressions are represented by their variable declarator.
            case "variable_declarator": return "variable"
            default: return nil
            }
        case "python":
            switch type {
            case "class_definition": return "type"
            case "function_definition": return "function"
            default: return nil
            }
        default: return nil
        }
    }
}
