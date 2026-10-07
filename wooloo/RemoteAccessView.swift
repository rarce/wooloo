import AppKit
import SwiftUI

/// The running tunnel's address, as a QR code for the Android app and as text for other clients.
struct RemoteAccessConnectionView: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    let hostname: String
    let sessionName: String

    private var user: String { NSUserName() }
    private var fingerprints: [String] { RemoteAccessHostKeys.fingerprints() }
    private var link: URL? {
        RemoteAccessLink.herdroid(hostname: hostname, user: user, session: sessionName,
                                  label: RemoteAccessSystem.machineName,
                                  herdrPath: RemoteAccessSystem.herdrExecutable, fingerprints: fingerprints)
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
                Text("Scan with the phone's camera to add this Mac to the Android app, then choose its SSH key.")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                copyRow("Hostname", hostname)
                copyRow("SSH user · Herdr session", "\(user) · \(sessionName)", copies: user)
                copyRow("From another computer", RemoteAccessLink.sshCommand(hostname: hostname, user: user))
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

/// The tunnel's state, with a start or stop button.
struct RemoteAccessStatusView: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    @ObservedObject var model: RemoteAccessModel

    var body: some View {
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
            } else {
                Button("Start") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.cloudflaredPath == nil)
            }
        }
    }

    private var text: String {
        switch model.state {
        case .stopped: "Off"
        case .starting: "Connecting to Cloudflare and publishing the address…"
        case .running(let hostname): "On at \(hostname)"
        case .failed(let message): message
        }
    }

    private var symbol: String {
        switch model.state {
        case .stopped: "circle"
        case .starting: "arrow.triangle.2.circlepath"
        case .running: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch model.state {
        case .stopped, .starting: theme.subtext
        case .running: theme.success
        case .failed: theme.warning
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
        case .running: theme.success
        case .failed: theme.warning
        case .stopped, .starting: theme.subtext
        }
    }

    private var help: String {
        switch model.state {
        case .running(let hostname): "Remote access on at \(hostname)"
        case .failed(let message): "Remote access stopped: \(message)"
        case .stopped, .starting: "Remote access is connecting"
        }
    }
}
