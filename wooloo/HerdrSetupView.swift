import AppKit
import SwiftUI

struct HerdrSetupView: View {
    @ObservedObject var runtime: HerdrRuntimeModel
    @Environment(\.woolooTheme) private var theme
    @State private var useBundled = true
    @State private var folder: URL?
    @State private var executable = HerdrRuntimePaths.externalCandidates.first(where: FileManager.default.isExecutableFile(atPath:))
        .map { URL(fileURLWithPath: $0) }
    @State private var existingSession = "default"

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 20)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(theme.accent)
                VStack(spacing: 8) {
                    Text("Welcome to wooloo").font(.title.weight(.semibold))
                    Text("A home for your terminals and coding agents.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Herdr", selection: $useBundled) {
                        Text("Use included Herdr").tag(true)
                        Text("Use my existing Herdr").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if useBundled {
                        Text("Herdr is included. No downloads or administrator password needed.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose a folder for your first Space").font(.headline)
                            HStack {
                                Text(folder?.path ?? "Your project folder")
                                    .lineLimit(2).textSelection(.enabled).foregroundStyle(.secondary)
                                Spacer()
                                Button("Choose Folder…") { chooseFolder() }
                            }
                        }
                        Text("Your terminals keep running when you close wooloo. Git and agent CLIs are optional and can be installed separately.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack {
                            Text(executable?.path ?? "Select the Herdr executable")
                                .lineLimit(2).foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose Herdr…") { chooseExecutable() }
                        }
                        TextField("Running session", text: $existingSession)
                            .textFieldStyle(.roundedBorder)
                        Text("Connects to an existing running session. Its server and configuration stay under your control.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = runtime.error {
                        Text(error).font(.callout).foregroundStyle(theme.warning).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if runtime.isBusy {
                            ProgressView().controlSize(.small)
                            Text(runtime.progress).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if runtime.canDismissSetup {
                            Button("Cancel") { runtime.showsSetup = false }
                        }
                        Button(useBundled ? "Create Space and Start" : "Connect") {
                            Task {
                                await runtime.finish(useBundled: useBundled, executable: executable,
                                                     session: useBundled ? runtime.managedSessionName : existingSession.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     folder: folder)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(useBundled ? folder == nil : executable == nil || existingSession.isEmpty)
                    }
                }
                .disabled(runtime.isBusy)
                .padding(24)
                .background(theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 590)
                Spacer(minLength: 20)
            }
            .padding(28)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.contentBackground)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.begin { response in if response == .OK { folder = panel.url } }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use Herdr"
        panel.begin { response in if response == .OK { executable = panel.url } }
    }
}
