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
    /// The herdr-core option, offered while herdr-core connections are turned on in Settings.
    @State private var usesCore = false
    @State private var coreExecutable = HerdrCoreSupport.locateLocal()
    @State private var coreSession = "default"
    @State private var confirmsCoreInstall = false
    @State private var installingCore = false
    @State private var coreInstallNotice: String?

    private enum Choice: Hashable { case bundled, existing, core }
    private var choice: Binding<Choice> {
        Binding(get: { usesCore ? .core : useBundled ? .bundled : .existing },
                set: { usesCore = $0 == .core; if $0 != .core { useBundled = $0 == .bundled } })
    }

    /// Installs herdr-core on this Mac after the user confirmed it, then finds it as on launch.
    private func installCore() {
        installingCore = true
        coreInstallNotice = "Installing herdr-core \(HerdrCoreInstall.version)…"
        Task {
            defer { installingCore = false }
            do {
                let (outcome, found) = try await WorkspaceFiles.blocking(on: nil) {
                    (try HerdrCoreInstall.installLocally(), HerdrCoreSupport.locateLocal())
                }
                coreExecutable = found
                switch outcome {
                case .present(let path): coreInstallNotice = "herdr-core is already installed (\(path)); nothing was changed."
                case .installed(let path): coreInstallNotice = "Installed herdr-core \(HerdrCoreInstall.version) at \(path)."
                }
            } catch {
                coreInstallNotice = error.localizedDescription
            }
        }
    }

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
                    Picker("Herdr", selection: choice) {
                        Text("Use included Herdr").tag(Choice.bundled)
                        Text("Use my existing Herdr").tag(Choice.existing)
                        if HerdrCoreSupport.isEnabled { Text("Use herdr-core (preview)").tag(Choice.core) }
                    }
                    .pickerStyle(.segmented)
                    if usesCore {
                        if let coreExecutable {
                            Text("Found herdr-core at \(coreExecutable).")
                                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        } else {
                            HStack {
                                Text("herdr-core (hc) is not installed on this Mac. wooloo can install it, or you can use its own installer. Its own updater keeps it current either way.")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Install herdr-core \(HerdrCoreInstall.version)…") { confirmsCoreInstall = true }
                                    .disabled(installingCore)
                                Link("Get herdr-core", destination: URL(string: "https://herdr.dev/core")!)
                                Button("Check Again") { coreExecutable = HerdrCoreSupport.locateLocal() }
                                    .disabled(installingCore)
                            }
                            .alert("Install herdr-core on this Mac?", isPresented: $confirmsCoreInstall) {
                                Button("Install") { installCore() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("wooloo downloads herdr-core \(HerdrCoreInstall.version) from releases.herdr.dev and checks it against the checksum built into wooloo. As herdr.dev/core's installer does, it checks Herdr's code signature and installs Herdr Core.app in ~/.local/share/herdr-core, with hc and herdr-core in ~/.local/bin. A herdr-core that is already there is kept.")
                            }
                        }
                        if let coreInstallNotice {
                            Text(coreInstallNotice).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        TextField("Session", text: $coreSession)
                            .textFieldStyle(.roundedBorder)
                        Text("Preview: wooloo keeps its Spaces, tabs and splits in the core, shows the official app's Spaces read-only, and draws terminals itself. Starting a session starts the core if it is not running.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if useBundled {
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
                        if usesCore {
                            Button("Connect to herdr-core") {
                                runtime.chooseCore(session: coreSession.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(coreExecutable == nil || coreSession.trimmingCharacters(in: .whitespaces).isEmpty)
                        } else {
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
