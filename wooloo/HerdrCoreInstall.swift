import Foundation

/// Installs herdr-core on a remote host, only when the user asks (docs/proposals/herdr-core-backend.md,
/// §8 and decision D3). Core releases have no signature independent of the release server, so
/// the SHA-256 of each build is pinned here, from the release's manifest, and checked on the
/// host before anything is installed. An existing core is never replaced: Core's own updater
/// (`hc update`) or the official app own it from then on.
enum HerdrCoreInstall {
    static let version = "0.1.21"

    struct Build: Equatable, Sendable {
        let url: String
        let sha256: String
    }

    /// `releases.herdr.dev/core/0.1.21/manifest.json`, by `uname` target.
    static let builds: [String: Build] = [
        "linux-x86_64": Build(url: "https://releases.herdr.dev/core/0.1.21/herdr-core-linux-x86_64.tar.gz",
                              sha256: "78424755c10a40dde38a0bdb55c20ac19706e9ae05ed68fc2acf1fcff0d941c1"),
        "linux-aarch64": Build(url: "https://releases.herdr.dev/core/0.1.21/herdr-core-linux-aarch64.tar.gz",
                               sha256: "e844a2bfab48a226097679d076bc83042fe57fccef5387ef802e5b24e78b529a"),
        "macos-x86_64": Build(url: "https://releases.herdr.dev/core/0.1.21/herdr-core-macos-x86_64.tar.gz",
                              sha256: "e377e1d342cddce0346da5b2f3c281b9701e4731c00024c7c5028265e77a217f"),
        "macos-aarch64": Build(url: "https://releases.herdr.dev/core/0.1.21/herdr-core-macos-aarch64.tar.gz",
                               sha256: "1ab38dd9270f63a8f794d6d60e8702eb0d1c85a72bda85d735e5eea43f05ffed"),
    ]

    static let presentMarker = "wooloo-core-present"
    static let installedMarker = "wooloo-core-installed"

    enum Outcome: Equatable, Sendable {
        /// A core was already there; nothing was changed.
        case present(String)
        case installed(String)
    }

    /// The script run on the host with `/bin/sh`. It looks for a core where the connection does,
    /// and stops if one is there. Otherwise it downloads the pinned build for the host's
    /// platform with curl or wget and checks its hash. It installs `~/.local/bin/herdr-core`,
    /// and `hc` beside it unless some `hc` already exists (some window managers ship one).
    static var script: String {
        let cases = builds.keys.sorted().map { target -> String in
            let build = builds[target]!
            return "    \(target)) url=\(WorkspaceFiles.quote(build.url)); want=\(build.sha256) ;;"
        }.joined(separator: "\n")
        let discovery = HerdrRemoteBridge.coreDiscoveryScript
            .replacingOccurrences(of: """
                if [ -z "$h" ]; then
                    printf '%s\\n' 'herdr-core (hc) is not installed on this host' >&2
                    exit 127
                fi
                """, with: "")
        return """
        set -u
        \(discovery)
        if [ -n "$h" ]; then
            printf '%s %s\\n' \(presentMarker) "$h"
            exit 0
        fi
        fail() { printf 'herdr-core install: %s\\n' "$*" >&2; exit 1; }
        case "$(uname -s)" in
            Linux) os=linux ;;
            Darwin) os=macos ;;
            *) fail "herdr-core runs on Linux and macOS only" ;;
        esac
        case "$(uname -m)" in
            x86_64 | amd64) arch=x86_64 ;;
            arm64 | aarch64) arch=aarch64 ;;
            *) fail "no herdr-core build for $(uname -m)" ;;
        esac
        case "$os-$arch" in
        \(cases)
            *) fail "no herdr-core build for $os-$arch" ;;
        esac
        command -v tar >/dev/null 2>&1 || fail "needs tar"
        tmp=$(mktemp -d) || fail "cannot create a temporary directory"
        trap 'rm -rf "$tmp"' EXIT
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$url" -o "$tmp/hc.tar.gz" || fail "download failed: $url"
        elif command -v wget >/dev/null 2>&1; then
            wget -q -O "$tmp/hc.tar.gz" "$url" || fail "download failed: $url"
        else
            fail "needs curl or wget"
        fi
        if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/hc.tar.gz" | cut -d' ' -f1)
        elif command -v shasum >/dev/null 2>&1; then got=$(shasum -a 256 "$tmp/hc.tar.gz" | cut -d' ' -f1)
        else fail "needs sha256sum or shasum"; fi
        [ "$got" = "$want" ] || fail "the download does not match the checksum wooloo pins; nothing was installed"
        tar -xzf "$tmp/hc.tar.gz" -C "$tmp" || fail "cannot unpack the download"
        [ -f "$tmp/herdr-core" ] || fail "the archive has no herdr-core"
        bin="$HOME/.local/bin"
        mkdir -p "$bin" || fail "cannot create $bin"
        [ ! -e "$bin/herdr-core" ] || fail "$bin/herdr-core already exists; nothing was replaced"
        cp "$tmp/herdr-core" "$bin/herdr-core.wooloo-staged" && chmod 755 "$bin/herdr-core.wooloo-staged" \\
            || fail "cannot write $bin"
        "$bin/herdr-core.wooloo-staged" --version >/dev/null 2>&1 \\
            || { rm -f "$bin/herdr-core.wooloo-staged"; fail "the downloaded herdr-core does not run on this host"; }
        mv "$bin/herdr-core.wooloo-staged" "$bin/herdr-core" || fail "cannot install $bin/herdr-core"
        if ! command -v hc >/dev/null 2>&1 && [ ! -e "$bin/hc" ]; then ln -s herdr-core "$bin/hc"; fi
        printf '%s %s\\n' \(installedMarker) "$bin/herdr-core"
        """
    }

    /// What the script reported on its last line.
    static func outcome(of output: String) -> Outcome? {
        guard let line = output.split(whereSeparator: \.isNewline).last.map(String.init) else { return nil }
        if line.hasPrefix(presentMarker + " ") { return .present(String(line.dropFirst(presentMarker.count + 1))) }
        if line.hasPrefix(installedMarker + " ") { return .installed(String(line.dropFirst(installedMarker.count + 1))) }
        return nil
    }

    /// Runs the install on `machine` over wooloo's SSH; call it inside `WorkspaceFiles.blocking(on:)`.
    @available(*, noasync, message: "Blocks its thread: call it inside WorkspaceFiles.blocking")
    static func install(on machine: HerdrMachineProfile) throws -> Outcome {
        let data = try WorkspaceFiles.ssh(machine, "/bin/sh -c " + WorkspaceFiles.quote(script), limit: 64_000,
                                          timeout: 180, label: "herdr-core install")
        guard let outcome = outcome(of: String(decoding: data, as: UTF8.self)) else {
            throw WorkspaceFileError.message("The herdr-core install did not finish.")
        }
        return outcome
    }
}
