import Foundation

/// The Herdr TUI server reached through its JSON socket, `herdr.sock` (or the local socket of
/// `HerdrRemoteBridge` for an SSH session).
struct TUISessionBackend: SessionBackend {
    let socketPath: String

    var kind: BackendKind { .tui }

    /// Blocks its thread; `HerdrStore` calls it inside `BlockingWork.run`.
    func perform(_ command: SessionCommand) throws {
        let request = command.herdrRequest
        let data = try HerdrSocket.request(path: socketPath, method: request.method, params: request.params)
        if command == .reloadConfig { try Self.requireApplied(data) }
    }

    /// Herdr answers a reload with its status and diagnostics rather than an error.
    static func requireApplied(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["result"] as? [String: Any],
              let status = response["status"] as? String else {
            throw HerdrConfigError.validation("Unexpected response from Herdr reload")
        }
        if status != "applied" {
            let details = (response["diagnostics"] as? [String] ?? []).joined(separator: "\n")
            throw HerdrConfigError.validation("Herdr reload: \(status). \(details)")
        }
    }
}
