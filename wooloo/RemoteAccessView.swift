import AppKit
import SwiftUI

/// Connection details shared with the phone; host identity always comes from the selected machine.
struct RemoteAccessConnectionView: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    let hostname: String
    let connection: MobileSSHConnection
    var transport: RemoteAccessLink.Transport = .cloudflare
    var port: Int = 22

    private var link: URL? {
        RemoteAccessLink.herdroid(hostname: hostname, user: connection.user, session: connection.session,
                                  label: connection.label, herdrPath: connection.herdrPath,
                                  fingerprints: connection.fingerprints, transport: transport, port: port)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            if let link, let image = RemoteAccessLink.qrImage(for: link) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 168, height: 168)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("QR code for the Android app")
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Scan in wooloo mobile to add \(connection.label) and session \(connection.session), then select the phone's SSH key authorized below.")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                copyRow("Hostname", transport == .ssh ? "\(hostname):\(port)" : hostname)
                copyRow("SSH user · Herdr session", "\(connection.user) · \(connection.session)", copies: connection.user)
                copyRow("From another computer", transport == .cloudflare
                        ? RemoteAccessLink.sshCommand(hostname: hostname, user: connection.user)
                        : "ssh -p \(port) \(WorkspaceFiles.quote(connection.user + "@" + hostname))")
                if let link {
                    Button("Copy App Link", systemImage: "link") { AppActions.copy(link.absoluteString) }
                }
            }
        }
    }

    private func copyRow(_ title: String, _ value: String, copies: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: typography.caption))
                .foregroundStyle(theme.subtext)
            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: typography.secondary, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Button {
                    AppActions.copy(copies ?? value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }
}

/// The tunnel's state, with a start or stop button, and the confirmation asked for when the
/// check did not find key-only SSH.
struct RemoteAccessStatusView: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    @ObservedObject var model: RemoteAccessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(text)
                    .font(.system(size: typography.body))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if model.isActive {
                    Button("Stop") { model.stop() }
                } else if case .needsConfirmation = model.state {
                    EmptyView()
                } else {
                    Button("Start") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.cloudflaredPath == nil)
                }
            }
            if case .needsConfirmation = model.state {
                Text("wooloo does not change sshd's sign-in methods. Start anyway only if you accept that risk; "
                     + "your confirmation is not a check, and the status will say the tunnel runs unverified.")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Start Anyway", role: .destructive) { model.startDespiteCheck() }
                    Button("Cancel") { model.cancelStart() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private var text: String {
        switch model.state {
        case .stopped: "Off"
        case .checking: "Checking which sign-in methods this Mac's SSH server accepts…"
        case .needsConfirmation(let check): check.summary
        case .starting: "Connecting to Cloudflare and publishing the address…"
        case .running(let hostname):
            model.runsWithoutVerifiedKeys
                ? "On at \(hostname), without verified key-only SSH"
                : "On at \(hostname)"
        case .failed(let message): message
        }
    }

    private var symbol: String {
        switch model.state {
        case .stopped: "circle"
        case .checking, .starting: "arrow.triangle.2.circlepath"
        case .running: model.runsWithoutVerifiedKeys ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
        case .needsConfirmation, .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch model.state {
        case .stopped, .checking, .starting: theme.subtext
        case .running: model.runsWithoutVerifiedKeys ? theme.warning : theme.success
        case .needsConfirmation, .failed: theme.warning
        }
    }
}

/// The sidebar's mark while the tunnel runs; it opens the Remote Access settings.
struct RemoteAccessIndicator: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    @ObservedObject var model = RemoteAccessModel.shared
    let open: () -> Void

    var body: some View {
        if model.state != .stopped {
            Button(action: open) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: typography.body))
                    .foregroundStyle(color)
                    .frame(width: 29, height: typography.metric(29))
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }

    private var color: Color {
        switch model.state {
        case .running: model.runsWithoutVerifiedKeys ? theme.warning : theme.success
        case .failed, .needsConfirmation: theme.warning
        case .stopped, .checking, .starting: theme.subtext
        }
    }

    private var help: String {
        switch model.state {
        case .running(let hostname):
            model.runsWithoutVerifiedKeys ? "Remote access on at \(hostname), without verified key-only SSH"
                : "Remote access on at \(hostname)"
        case .failed(let message): "Remote access stopped: \(message)"
        case .needsConfirmation: "Remote access is waiting for your confirmation"
        case .checking: "Remote access is checking this Mac's SSH sign-in"
        case .stopped, .starting: "Remote access is connecting"
        }
    }
}

/// An administration layer over Herdr's saved machines, shared with its CLI.
struct HerdrMachineManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [HerdrMachineProfile] = []
    @State private var target = ""
    @State private var label = ""
    @State private var session = "default"
    @State private var busy = false
    @State private var error: String?
    @State private var renaming: HerdrMachineProfile?
    @State private var newLabel = ""
    @State private var removing: HerdrMachineProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Remote Hosts").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Manage Herdr's saved SSH machines for remote files and changes. SSH aliases and keys use your OpenSSH configuration.")
                .foregroundStyle(.secondary)
            List(profiles) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.label).fontWeight(.medium)
                        Text("\(profile.target) · \(profile.session)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(profile.enabled ? "Disable" : "Enable") {
                        perform([profile.enabled ? "disable" : "enable", profile.id])
                    }
                    Button("Rename") { newLabel = profile.label; renaming = profile }
                    Button("Remove", role: .destructive) { removing = profile }
                }
            }
            .frame(minHeight: 140)
            GroupBox("Add SSH host") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("SSH target: user@host, SSH alias, or ssh://user@host:port", text: $target)
                    HStack {
                        TextField("Label (optional)", text: $label)
                        TextField("Herdr session", text: $session)
                    }
                    Text("Herdr prepares the remote server before saving. Set up SSH key access and trust the host with ssh in Terminal first if authentication is required.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Add Host") {
                        var arguments = ["add", target.trimmingCharacters(in: .whitespacesAndNewlines),
                                         "--remote-session", session.trimmingCharacters(in: .whitespacesAndNewlines)]
                        if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            arguments += ["--label", label.trimmingCharacters(in: .whitespacesAndNewlines)]
                        }
                        perform(arguments, adding: true)
                    }
                    .disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || target.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-")
                              || session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(6)
            }
            if busy { ProgressView("Waiting for Herdr…") }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Button("Refresh") { perform() }
        }
        .padding(20).frame(width: 680)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .task { perform() }
        .alert("Rename Host", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Label", text: $newLabel)
            Button("Save") {
                if let renaming { perform(["rename", renaming.id, "--label", newLabel]) }
                renaming = nil
            }.disabled(newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Remove saved host?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { perform(["remove", removing.id]) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("This removes the host from Herdr's saved machines. Remote files and sessions remain on the host.")
        }
    }

    private func perform(_ arguments: [String]? = nil, adding: Bool = false) {
        busy = true
        error = nil
        Task {
            let result = await BlockingWork.run {
                Result {
                    if let arguments { try WorkspaceFiles.manageMachine(arguments) }
                    return try WorkspaceFiles.machines(includeDisabled: true)
                }
            }
            busy = false
            switch result {
            case .success(let profiles):
                self.profiles = profiles
                if adding { target = ""; label = "" }
            case .failure(let failure): error = failure.localizedDescription
            case nil: break
            }
        }
    }
}
