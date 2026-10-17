import SwiftUI

/// Immutable contents captured for one read-only comparison. They never become a save base.
struct DiffSnapshotSides: Equatable {
    let old: String
    let new: String
}

struct WorkspaceDiskComparison: Identifiable {
    let id = UUID()
    let documentID: String
    let location: WorkspaceFileLocation
    let path: String
    let buffer: String
    let syntaxOverride: String?
    var disk: String?
    var diskVersion: String?
    var patch = ""
    var error: String?
    var isLoading = true

    var source: DiffSource {
        DiffSource(location: location, path: path, originalPath: nil, commit: nil, scope: .all,
                   snapshots: disk.map { DiffSnapshotSides(old: $0, new: buffer) })
    }
}

/// Owns presentation outside the editor hierarchy, including while an SSH read is pending.
struct WorkspaceDiskComparisonPresenter: View {
    @ObservedObject var store: WorkspaceDocumentStore

    var body: some View {
        Color.clear.sheet(item: $store.diskComparison) { _ in
            WorkspaceDiskComparisonView(store: store)
                .allowsQuitWhileShown()
        }
    }
}

struct WorkspaceDiskComparisonView: View {
    @ObservedObject var store: WorkspaceDocumentStore
    @AppStorage(DiffDisplayMode.storageKey) private var mode = DiffDisplayMode.unified
    @Environment(\.woolooTheme) private var theme

    var body: some View {
        if let comparison = store.diskComparison { content(comparison) }
    }

    private func content(_ comparison: WorkspaceDiskComparison) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compare with Disk").font(.headline)
                    Text(comparison.path).font(.caption).textSelection(.enabled)
                    Text("Disk → Your Buffer · Read-only snapshots")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Display", selection: $mode) {
                    ForEach(DiffDisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 170)
                Button("Refresh") { store.compareWithDisk(comparison.documentID) }.disabled(comparison.isLoading)
                Button("Done") { store.diskComparison = nil }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if comparison.isLoading {
                ProgressView("Reading disk…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = comparison.error {
                Text(error).foregroundStyle(theme.warning).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if comparison.patch.isEmpty {
                Text("No differences between disk and your buffer.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WorkspaceDiffView(text: comparison.patch, source: comparison.source, mode: mode,
                                  syntaxOverride: comparison.syntaxOverride)
            }
        }
        .frame(minWidth: 700, idealWidth: 1000, minHeight: 420, idealHeight: 650)
        .background(theme.contentBackground)
    }
}
