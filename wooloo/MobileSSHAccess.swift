import Foundation

/// A public identity shared by the phone. Never accepts authorized_keys options or shell commands.
struct MobileSSHPublicKey: Equatable, Sendable {
    let line: String
    let fingerprint: String

    init(_ text: String) throws {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.utf8.count <= 16_384,
              !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }) else {
            throw WorkspaceFileError.message("Paste one OpenSSH public key, on a single line.")
        }
        let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 2, let data = Data(base64Encoded: fields[1]) else {
            throw WorkspaceFileError.message("Paste the public key from wooloo mobile, not a private key or a command.")
        }
        var offset = 0
        func field() -> Data? {
            guard data.count - offset >= 4 else { return nil }
            let size = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard size <= data.count - offset else { return nil }
            defer { offset += size }
            return data.subdata(in: offset..<(offset + size))
        }
        guard let type = field(), String(data: type, encoding: .utf8) == fields[0] else {
            throw WorkspaceFileError.message("The public key's type does not match its contents.")
        }
        let valid: Bool
        switch fields[0] {
        case "ssh-ed25519": valid = field()?.count == 32
        case "ssh-rsa":
            let exponent = field()
            let modulus = field()
            valid = exponent?.contains(where: { $0 != 0 }) == true
                && (modulus.map { (128...2049).contains($0.count) } ?? false)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curve = field().flatMap { String(data: $0, encoding: .utf8) }
            let point = field()
            let sizes = ["nistp256": 65, "nistp384": 97, "nistp521": 133]
            valid = curve.map { fields[0] == "ecdsa-sha2-" + $0 && point?.count == sizes[$0] } == true
                && point?.first == 4
        default: valid = false
        }
        guard valid, offset == data.count,
              let fingerprint = RemoteAccessHostKeys.fingerprint(ofPublicKeyLine: line) else {
            throw WorkspaceFileError.message("Use a valid Ed25519, RSA or ECDSA public key from wooloo mobile.")
        }
        self.line = fields[0] + " " + fields[1] + (fields.count == 3 ? " " + fields[2] : "")
        self.fingerprint = fingerprint
    }
}

/// Captures the selected machine and verified account together; a later UI selection cannot
/// redirect an authorization to another machine. Phone-facing host/port can differ from SSH aliases.
struct MobileSSHConnection: Sendable {
    let machine: HerdrMachineProfile?
    let hostname: String
    let port: Int
    let user: String
    let homeDirectory: String
    let session: String
    let label: String
    let herdrPath: String?
    let fingerprints: [String]
    let usesProxy: Bool

    var authorizedKeysPath: String { homeDirectory + "/.ssh/authorized_keys" }
    var account: String { "\(user)@\(hostname):\(port)" }

    func link(hostname: String, port: String) -> URL? {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.range(of: #"^(?:[A-Za-z0-9._-]+|\[[0-9A-Fa-f:.]+\])$"#, options: .regularExpression) != nil,
              let number = Int(port), (1...65535).contains(number) else { return nil }
        return RemoteAccessLink.herdroid(hostname: host, user: user, session: session, label: label,
                                        herdrPath: herdrPath, fingerprints: fingerprints,
                                        transport: .ssh, port: number)
    }
}

enum MobileSSHAccess {
    struct ResolvedEndpoint: Equatable {
        let hostname: String
        let port: Int
        let usesProxy: Bool

        init(configuration: String) throws {
            var values: [String: String] = [:]
            for line in configuration.split(separator: "\n") {
                let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                if fields.count == 2 { values[String(fields[0])] = String(fields[1]) }
            }
            guard let hostname = values["hostname"], !hostname.isEmpty,
                  let port = values["port"].flatMap(Int.init), (1...65535).contains(port) else {
                throw WorkspaceFileError.message("Could not resolve the saved host's SSH hostname and port.")
            }
            self.hostname = hostname.contains(":") && !hostname.hasPrefix("[") ? "[\(hostname)]" : hostname
            self.port = port
            usesProxy = ["proxyjump", "proxycommand"].contains { values[$0].map { $0 != "none" } ?? false }
        }
    }

    /// NUL framing separates account metadata from public host-key lines. Only reads the target.
    static let probeScript = #"""
    set -eu
    printf '%s\0%s\0' "$(id -un)" "$HOME"
    task_herdr=''
    task_found=$(command -v herdr || true)
    for task_candidate in "$task_found" "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr /home/linuxbrew/.linuxbrew/bin/herdr "$HOME/.cargo/bin/herdr" "$HOME/.local/share/mise/installs/herdr/\#(HerdrRuntimePaths.version)/bin/herdr" "$HOME/.local/share/mise/installs/herdr/\#(HerdrRuntimePaths.version)/herdr" "$HOME/.nix-profile/bin/herdr" /run/current-system/sw/bin/herdr /nix/var/nix/profiles/default/bin/herdr; do
        [ -x "$task_candidate" ] || continue
        task_capability=$("$task_candidate" --session "$1" remote-api-bridge --check </dev/null 2>/dev/null || true)
        if [ "$task_capability" = herdr-api-bridge-v1 ]; then task_herdr=$task_candidate; break; fi
    done
    if [ -z "$task_herdr" ]; then printf '%s\n' 'A compatible Herdr executable could not be found on the remote host.' >&2; exit 1; fi
    printf '%s\0' "$task_herdr"
    for task_key in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
        if [ -r "$task_key" ]; then cat "$task_key"; printf '\n'; fi
    done
    """#

    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking(on:)")
    static func prepare(machine: HerdrMachineProfile?, session: String) throws -> MobileSSHConnection {
        guard let machine else {
            return MobileSSHConnection(machine: nil, hostname: "localhost", port: 22, user: NSUserName(),
                                       homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                                       session: session, label: RemoteAccessSystem.machineName,
                                       herdrPath: RemoteAccessSystem.herdrExecutable,
                                       fingerprints: RemoteAccessHostKeys.fingerprints(), usesProxy: false)
        }
        let endpoint = WorkspaceFiles.SSHEndpoint(machine.target)
        guard !endpoint.destination.isEmpty, !endpoint.destination.hasPrefix("-") else {
            throw WorkspaceFileError.message("Invalid SSH target.")
        }
        var arguments = ["-G", "-T"]
        if let port = endpoint.port { arguments += ["-p", port] }
        arguments.append(endpoint.destination)
        let configuration = try WorkspaceFiles.run(WorkspaceFiles.sshExecutable, arguments, limit: 128_000,
                                                    label: "mobile SSH configuration")
        let resolved = try ResolvedEndpoint(configuration: String(decoding: configuration, as: UTF8.self))
        let data = try WorkspaceFiles.remoteOutput(machine, script: "sh -c " + WorkspaceFiles.quote(probeScript)
                                                   + " sh " + WorkspaceFiles.quote(session),
                                                   label: "mobile SSH identity")
        return try connection(machine: machine, session: session, endpoint: resolved, metadata: data)
    }

    static func connection(machine: HerdrMachineProfile, session: String, endpoint: ResolvedEndpoint,
                           metadata: Data) throws -> MobileSSHConnection {
        let fields = metadata.split(separator: 0, maxSplits: 3, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard fields.count == 4, !fields[0].isEmpty, fields[1].hasPrefix("/"), fields[1] != "/",
              !fields[0].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !fields[1].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceFileError.message("Could not read the remote SSH account and home directory. Nothing was authorized.")
        }
        let fingerprints = fields[3].split(separator: "\n").compactMap {
            RemoteAccessHostKeys.fingerprint(ofPublicKeyLine: String($0))
        }
        return MobileSSHConnection(machine: machine, hostname: endpoint.hostname, port: endpoint.port,
                                   user: fields[0], homeDirectory: fields[1], session: session, label: machine.label,
                                   herdrPath: fields[2].hasPrefix("/") ? fields[2] : nil,
                                   fingerprints: fingerprints, usesProxy: endpoint.usesProxy)
    }

    /// Only called after the user reviews the captured destination and key fingerprint.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking(on:)")
    static func authorize(_ key: MobileSSHPublicKey, on connection: MobileSSHConnection) throws -> Bool {
        let script = installationScript(homeDirectory: connection.homeDirectory, user: connection.user)
        let input = Data((key.line + "\n").utf8)
        let data: Data
        if let machine = connection.machine {
            data = try WorkspaceFiles.remoteOutput(machine, script: "sh -c " + WorkspaceFiles.quote(script),
                                                     label: "authorize mobile SSH key", input: input)
        } else {
            data = try WorkspaceFiles.run("/bin/sh", ["-c", script], input: input, limit: 4096,
                                           label: "authorize mobile SSH key")
        }
        switch String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "added": return true
        case "exists": return false
        default: throw WorkspaceFileError.message("The SSH server did not confirm key authorization. Check authorized_keys before retrying.")
        }
    }

    /// A lock and atomic replacement protect existing entries. An existing key with options is
    /// left as-is: authorizing it again must never remove restrictions imposed by an administrator.
    static func installationScript(homeDirectory: String, user: String) -> String {
        "task_home=" + WorkspaceFiles.quote(homeDirectory) + "\n"
        + "task_user=" + WorkspaceFiles.quote(user) + "\n" + #"""
        set -eu
        umask 077
        task_fail() { printf '%s\n' "$1" >&2; exit 1; }
        [ "$(id -un)" = "$task_user" ] || task_fail 'The SSH account changed; reload Remote Access.'
        [ -d "$task_home" ] && [ -O "$task_home" ] || task_fail 'The account does not own its home directory.'
        task_directory="$task_home/.ssh"
        task_file="$task_directory/authorized_keys"
        [ ! -L "$task_directory" ] && [ ! -L "$task_file" ] || task_fail 'Refusing symbolic links in the SSH authorization path.'
        if [ ! -e "$task_directory" ]; then mkdir "$task_directory"; fi
        [ -d "$task_directory" ] && [ -O "$task_directory" ] || task_fail 'The account does not own its .ssh directory.'
        if [ -e "$task_file" ]; then
            [ -f "$task_file" ] && [ -O "$task_file" ] || task_fail 'authorized_keys is not a regular file owned by this account.'
        fi
        IFS= read -r task_key || task_fail 'No public key was received.'
        task_type=${task_key%% *}
        task_blob=${task_key#* }
        task_blob=${task_blob%% *}
        task_lock="$task_directory/.wooloo-authorized-keys.lock"
        mkdir "$task_lock" 2>/dev/null || task_fail 'Another authorization is in progress; retry after it finishes.'
        task_temp=''
        trap '[ -z "$task_temp" ] || rm -f "$task_temp"; rmdir "$task_lock"' EXIT
        trap 'exit 1' HUP INT TERM
        chmod 700 "$task_directory"
        if [ -f "$task_file" ]; then chmod 600 "$task_file"; fi
        if [ -f "$task_file" ]; then
            # Read bytes independently of the host locale, including existing non-UTF-8 options.
            task_scan=$(LC_ALL=C awk -v kind="$task_type" -v blob="$task_blob" '
            function token(   value, c, quoted, escaped) {
                value = ""
                while (position <= length($0) && substr($0, position, 1) ~ /[ \t\r]/) position++
                for (; position <= length($0); position++) {
                    c = substr($0, position, 1)
                    if (!quoted && !escaped && c ~ /[ \t\r]/) { position++; break }
                    value = value c
                    if (escaped) escaped = 0
                    else if (c == "\\") escaped = 1
                    else if (c == "\"") quoted = !quoted
                }
                return value
            }
            /^[[:space:]]*#/ { next }
            {
                position = 1
                candidate = token()
                if (candidate !~ /^(ssh-|ecdsa-|sk-)/) candidate = token()
                candidate_blob = token()
                if (candidate == kind && candidate_blob == blob) found = 1
            }
            END { print (found ? "exists" : "missing") }
            ' "$task_file") || task_fail 'Could not inspect existing authorized_keys; no key was added.'
            case "$task_scan" in
                exists) printf 'exists\n'; exit 0;;
                missing) ;;
                *) task_fail 'Could not inspect existing authorized_keys; no key was added.';;
            esac
        fi
        task_temp=$(mktemp "$task_directory/.authorized_keys.XXXXXXXX")
        if [ -f "$task_file" ]; then cat "$task_file" > "$task_temp"; printf '\n' >> "$task_temp"; fi
        printf '%s\n' "$task_key" >> "$task_temp"
        chmod 600 "$task_temp"
        mv -f "$task_temp" "$task_file"
        task_temp=''
        printf 'added\n'
        """#
    }
}
