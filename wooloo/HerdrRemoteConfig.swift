import Foundation

/// Identity and contents captured in one SSH read. The configured path may be a dotfiles link;
/// writes replace its resolved target and leave the link itself intact.
struct HerdrRemoteConfig: Sendable {
    let path: String
    let resolvedPath: String
    let user: String
    let host: String
    let executable: String
    let exists: Bool
    let text: String

    func replacingText(_ text: String) -> Self {
        Self(path: path, resolvedPath: resolvedPath, user: user, host: host,
             executable: executable, exists: true, text: text)
    }

    @available(*, noasync, message: "Call inside WorkspaceFiles.blocking(on:)")
    static func read(on machine: HerdrMachineProfile) throws -> Self {
        let script = prelude + HerdrRemoteBridge.executableDiscoveryScript(session: machine.session) + #"""

        task_exists=0
        [ ! -f "$task_file" ] || task_exists=1
        printf '%s\0' "$task_config" "$task_file" "$(id -un)" "$(hostname)" "$h" "$task_exists"
        if [ "$task_exists" = 1 ]; then cat "$task_file"; fi
        """#
        let data = try WorkspaceFiles.remoteOutput(machine, script: command(script), label: "read Herdr config",
                                                   limit: 1_048_576)
        let parts = data.split(separator: 0, maxSplits: 6, omittingEmptySubsequences: false)
        guard parts.count == 7 else { throw HerdrConfigError.validation("Invalid remote configuration response.") }
        let fields = try parts.map { data -> String in
            guard let value = String(data: data, encoding: .utf8), !value.contains("\0") else {
                throw HerdrConfigError.validation("config.toml must be UTF-8 text.")
            }
            return value
        }
        guard fields.prefix(6).allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              fields[0].hasPrefix("/"), fields[1].hasPrefix("/"), ["0", "1"].contains(fields[5]) else {
            throw HerdrConfigError.validation("Invalid remote configuration identity.")
        }
        return Self(path: fields[0], resolvedPath: fields[1], user: fields[2], host: fields[3],
                    executable: fields[4], exists: fields[5] == "1", text: fields[6])
    }

    /// Compares existence, resolved path and bytes before validation and again before replacement.
    /// This detects ordinary external edits; it is not a lock on other editors.
    @available(*, noasync, message: "Call inside WorkspaceFiles.blocking(on:)")
    func save(_ text: String, on machine: HerdrMachineProfile) throws {
        guard !text.contains("\0"), text.utf8.count <= 1_000_000 else {
            throw HerdrConfigError.validation("config.toml must be UTF-8 text smaller than 1 MB.")
        }
        let quote = WorkspaceFiles.quote
        let identity = """
        [ "$task_config" = \(quote(path)) ] && [ "$task_file" = \(quote(resolvedPath)) ] &&
        [ "$(id -un)" = \(quote(user)) ] && [ "$(hostname)" = \(quote(host)) ] ||
            task_fail 'The remote account, host or configuration path changed. Reload before saving.'
        h=\(quote(executable))
        """
        let script = Self.prelude + identity + "\n" + #"""
        task_directory=$(dirname "$task_file")
        mkdir -p "$task_directory"
        task_temporary=$(mktemp -d "$task_directory/.wooloo-config.XXXXXX")
        task_validation=
        trap 'if [ -n "$task_validation" ]; then rm -f "$task_validation"; fi; rm -rf "$task_temporary"' EXIT
        trap 'exit 1' HUP INT TERM
        IFS= read -r task_original || task_fail 'No original configuration was received.'
        printf '%s' "$task_original" | base64 -d > "$task_temporary/original"
        task_check_original() {
            task_resolve
        """# + "\n    [ \"$task_file\" = \(quote(resolvedPath)) ] || task_fail 'The configuration link changed. Reload before saving.'\n"
            + (exists
               ? "    [ -f \"$task_file\" ] && cmp -s \"$task_file\" \"$task_temporary/original\" || task_fail 'config.toml changed outside wooloo. Reload it before saving.'\n"
               : "    [ ! -e \"$task_file\" ] && [ ! -L \"$task_file\" ] || task_fail 'config.toml changed outside wooloo. Reload it before saving.'\n")
            + #"""
        }
        task_check_original
        if [ -f "$task_file" ]; then cp -p "$task_file" "$task_temporary/config.toml"; fi
        cat > "$task_temporary/config.toml"
        # Herdr resolves relative paths beside the configured path, even if it is a symlink.
        # Keep the validation copy there and the atomic replacement beside the resolved target.
        task_validation=$(mktemp "$(dirname "$task_config")/.wooloo-validate.XXXXXX")
        cp "$task_temporary/config.toml" "$task_validation"
        HERDR_CONFIG_PATH="$task_validation" "$h" config check >&2
        task_check_original
        mv -f "$task_temporary/config.toml" "$task_file"
        printf 'saved\n'
        """#
        let input = Data((Data(self.text.utf8).base64EncodedString() + "\n" + text).utf8)
        let result = try WorkspaceFiles.remoteOutput(machine, script: Self.command(script), label: "save Herdr config", input: input)
        guard result == Data("saved\n".utf8) else {
            throw HerdrConfigError.validation("The remote host did not confirm saving config.toml.")
        }
    }

    private static func command(_ script: String) -> String { "/bin/sh -c " + WorkspaceFiles.quote(script) }

    private static let prelude = #"""
    set -eu
    umask 077
    task_fail() { printf '%s\n' "$1" >&2; exit 1; }
    task_config=${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}
    case "$task_config" in /*) ;; *) task_fail 'The remote configuration path must be absolute.' ;; esac
    task_resolve() {
        task_ancestor=$task_config
        task_suffix=
        while [ ! -e "$task_ancestor" ] && [ ! -L "$task_ancestor" ]; do
            task_name=$(basename "$task_ancestor")
            case "$task_name" in .|..) task_fail 'Use a configuration path without dot components.' ;; esac
            task_suffix=/$task_name$task_suffix
            task_ancestor=$(dirname "$task_ancestor")
        done
        if [ -z "$task_suffix" ]; then
            [ -f "$task_ancestor" ] || task_fail 'config.toml is not a regular file or is a dangling link.'
        else
            [ -d "$task_ancestor" ] || task_fail 'The configuration parent is not a directory.'
        fi
        task_base=$(realpath "$task_ancestor") || task_fail 'Could not resolve config.toml.'
        task_file=${task_base%/}$task_suffix
    }
    task_resolve

    """#
}
