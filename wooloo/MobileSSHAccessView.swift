import SwiftUI

/// The public-key return path deliberately uses the phone's existing copy/share action.
/// Scanning a connection QR never silently grants a new device access to an account.
struct MobileSSHAccessView: View {
    @Environment(\.woolooTheme) private var theme
    let machine: HerdrMachineProfile?
    let session: String
    let tunnelHostname: String?
    @Binding var authorizing: Bool
    @State private var connection: MobileSSHConnection?
    @State private var hostname = ""
    @State private var port = "22"
    @State private var publicKey = ""
    @State private var loading = false
    @State private var error: String?
    @State private var result: String?
    @State private var pending: Authorization?

    private struct Authorization {
        let key: MobileSSHPublicKey
        let connection: MobileSSHConnection

        var explanation: String {
            "Add \(key.fingerprint) to \(connection.authorizedKeysPath) on \(connection.account)"
            + (connection.machine.map { " using saved host \($0.target)" } ?? " on this Mac")
            + ". This grants the phone SSH access as \(connection.user), across this account's sessions. "
            + "Existing keys and restrictions are kept. The .ssh directory will use 700 permissions and authorized_keys 600."
        }
    }

    private var parsedKey: Result<MobileSSHPublicKey, Error> { Result { try MobileSSHPublicKey(publicKey) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mobile access").font(.headline)
            if loading { ProgressView("Reading the selected SSH account…") }
            if let connection {
                Text("Destination: \(connection.label) · \(connection.account) · session \(connection.session)")
                    .fontWeight(.medium)
                    .textSelection(.enabled)
                if connection.machine != nil {
                    Text("The phone connects directly over SSH. Use a hostname and SSH port reachable from the phone's network. A public domain needs no Cloudflare tunnel when its SSH port is reachable.")
                        .foregroundStyle(theme.subtext)
                    if connection.usesProxy {
                        Label("This Mac uses an SSH proxy or jump host. The phone does not inherit that route; enter an address it can reach directly or use a VPN.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(theme.warning)
                    }
                    HStack {
                        TextField("Hostname reachable from the phone", text: $hostname)
                        TextField("SSH port", text: $port).frame(width: 90)
                    }
                    .textFieldStyle(.roundedBorder)
                    .disabled(authorizing)
                    if connection.link(hostname: hostname, port: port) != nil, let number = Int(port) {
                        RemoteAccessConnectionView(hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   connection: connection, transport: .ssh, port: number)
                    } else {
                        Text("Enter a hostname (IPv6 in brackets) and a port from 1 to 65535 to show the QR.")
                            .foregroundStyle(theme.warning)
                    }
                } else if let tunnelHostname {
                    RemoteAccessConnectionView(hostname: tunnelHostname, connection: connection)
                } else {
                    Text("Start the local tunnel to show this Mac's connection QR. You can authorize the phone's public key first.")
                        .foregroundStyle(theme.subtext)
                }
                if connection.fingerprints.isEmpty {
                    Text("The server's public host keys could not be read. Verify the host fingerprint on the phone when connecting.")
                        .foregroundStyle(theme.warning)
                }
                Divider()
                Text("Authorize the phone's public key").fontWeight(.medium)
                Text("In wooloo mobile, generate or select an SSH key and copy/share its public key. Paste that single public-key line here. The private key stays on the phone.")
                    .foregroundStyle(theme.subtext)
                TextField("ssh-ed25519 AAAA… wooloo-mobile", text: $publicKey, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .disabled(authorizing)
                    .onChange(of: publicKey) { _, _ in result = nil; error = nil }
                if !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    switch parsedKey {
                    case .success(let key):
                        Text(key.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    case .failure(let error):
                        Text(error.localizedDescription).foregroundStyle(theme.warning)
                    }
                }
                Text("wooloo will add this public key to \(connection.authorizedKeysPath) on \(connection.account)"
                     + (connection.machine.map { " through saved host \($0.target)" } ?? " on this Mac")
                     + ". This authorizes SSH access to the account, across all its sessions. Existing keys and restrictions are kept.")
                    .foregroundStyle(theme.subtext)
                    .textSelection(.enabled)
                HStack {
                    Button("Review Authorization…") {
                        if case .success(let key) = parsedKey { pending = Authorization(key: key, connection: connection) }
                    }
                    .disabled(authorizing || (try? parsedKey.get()) == nil)
                    if authorizing { ProgressView().controlSize(.small) }
                }
            }
            if let error { Text(error).foregroundStyle(theme.warning).textSelection(.enabled) }
            if let result { Text(result).foregroundStyle(theme.success).textSelection(.enabled) }
            if connection == nil && !loading {
                Button("Retry") { Task { await load() } }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .task { await load() }
        .alert("Authorize mobile SSH access?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), presenting: pending) { authorization in
            Button("Authorize Key") { Task { await authorize(authorization) } }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { authorization in
            Text(authorization.explanation)
        }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let prepared = try await WorkspaceFiles.blocking(on: machine) {
                try MobileSSHAccess.prepare(machine: machine, session: session)
            }
            guard !Task.isCancelled else { return }
            connection = prepared
            hostname = prepared.hostname
            port = String(prepared.port)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Could not prepare mobile access: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func authorize(_ authorization: Authorization) async {
        guard !authorizing else { return }
        pending = nil
        authorizing = true
        error = nil
        result = nil
        defer { authorizing = false }
        do {
            let added = try await WorkspaceFiles.blocking(on: authorization.connection.machine) {
                try MobileSSHAccess.authorize(authorization.key, on: authorization.connection)
            }
            result = added
                ? "Key authorized on \(authorization.connection.account). Select this key in wooloo mobile and connect."
                : "This key is already in \(authorization.connection.authorizedKeysPath) on \(authorization.connection.account). Its existing restrictions were kept."
        } catch {
            self.error = "Could not authorize the key on \(authorization.connection.account): \(error.localizedDescription)"
        }
    }
}
