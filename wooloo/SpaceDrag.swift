import SwiftUI
import UniformTypeIdentifiers

/// Window-local state. Provider nonces distinguish cancelled/foreign drags with matching IDs.
@MainActor
final class SpaceDragModel: ObservableObject {
    static let type = UTType(exportedAs: "dev.wooloo.space", conformingTo: .data)
    struct Source {
        let id: String
        let nonce: String
        let connection: HerdrActionConnection
    }
    struct Target: Equatable {
        let storeID: ObjectIdentifier
        let workspaceID: String?
        let after: Bool
        let terminal: Bool
    }
    private(set) var source: Source?
    @Published private(set) var target: Target?

    func hover(_ target: Target?) {
        if self.target != target { self.target = target }
    }

    func begin(_ id: String, store: HerdrStore) -> NSItemProvider {
        let nonce = UUID().uuidString
        source = Source(id: id, nonce: nonce, connection: HerdrActionConnection(store))
        hover(nil)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { completion in
            completion(Data(nonce.utf8), nil)
            return nil
        }
        return provider
    }

    func cancel() { source = nil; hover(nil) }

    /// The payload is data, never text that could be pasted into a terminal.
    static func payload(_ provider: NSItemProvider, type: UTType) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
            }
        }
    }
}

struct SpaceDropModifier: ViewModifier {
    @ObservedObject var store: HerdrStore
    @ObservedObject var spaces: SpaceDragModel
    @ObservedObject var tabs: TabDragModel
    let workspaceID: String?
    @State private var height: CGFloat = 0
    @Environment(\.woolooTheme) private var theme

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .onDrop(of: [SpaceDragModel.type, TabDragModel.type],
                    delegate: SpaceDropDelegate(store: store, spaces: spaces, tabs: tabs,
                                                workspaceID: workspaceID, height: height))
            .overlay {
                if let target = spaces.target, target.storeID == ObjectIdentifier(store), target.workspaceID == workspaceID {
                    if target.terminal {
                        RoundedRectangle(cornerRadius: 4).stroke(theme.accent, lineWidth: 2)
                            .allowsHitTesting(false)
                    } else {
                        VStack {
                            if target.after { Spacer(minLength: 0) }
                            Rectangle().fill(theme.accent).frame(height: 2)
                            if !target.after { Spacer(minLength: 0) }
                        }.allowsHitTesting(false)
                    }
                }
            }
    }
}

struct SpaceDropDelegate: DropDelegate {
    let store: HerdrStore
    let spaces: SpaceDragModel
    let tabs: TabDragModel
    let workspaceID: String?
    let height: CGFloat

    private func terminal(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [TabDragModel.type]) &&
        tabs.spaceConnection?.validStore === store && tabs.draggedTerminalTab != nil
    }

    private func accepts(_ info: DropInfo) -> Bool {
        guard store.isConnected, !store.spaceMoveInFlight else { return false }
        if terminal(info),
           let id = tabs.draggedTerminalTab {
            return store.tabSpaceMoveRefusal(id, to: workspaceID) == nil
        }
        return workspaceID != nil && info.hasItemsConforming(to: [SpaceDragModel.type])
            && spaces.source?.connection.validStore === store
            && spaces.source?.id != workspaceID
    }

    func validateDrop(info: DropInfo) -> Bool { accepts(info) }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: accepts(info) ? .move : .forbidden)
    }
    func dropExited(info: DropInfo) { spaces.hover(nil) }

    private func update(_ info: DropInfo) {
        spaces.hover(accepts(info) ? .init(storeID: ObjectIdentifier(store), workspaceID: workspaceID,
                                             after: info.location.y >= height / 2, terminal: terminal(info)) : nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard accepts(info) else { spaces.hover(nil); return false }
        let isTerminal = terminal(info)
        let type = isTerminal ? TabDragModel.type : SpaceDragModel.type
        guard let provider = info.itemProviders(for: [type]).first,
              let nonce = isTerminal ? tabs.spaceNonce : spaces.source?.nonce,
              let id = isTerminal ? tabs.draggedTerminalTab : spaces.source?.id,
              let connection = isTerminal ? tabs.spaceConnection : spaces.source?.connection else { return false }
        let after = info.location.y >= height / 2
        let shouldFollow = tabs.spaceShouldFollow
        spaces.hover(nil)
        Task { @MainActor in
            let payload = await SpaceDragModel.payload(provider, type: type)
            guard payload == nonce,
                  connection.validStore === store else { return }
            if isTerminal {
                guard tabs.spaceNonce == nonce else { return }
                tabs.cancel()
                _ = store.moveTab(id, toWorkspace: workspaceID, shouldFollow: shouldFollow)
            } else {
                guard spaces.source?.nonce == nonce, let workspaceID else { return }
                spaces.cancel()
                _ = store.moveWorkspace(id, beside: workspaceID, after: after)
            }
        }
        return true
    }
}
