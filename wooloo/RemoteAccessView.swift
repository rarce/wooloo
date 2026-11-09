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
