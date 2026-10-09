import Combine
import Foundation
import Sparkle

/// Updates wooloo from its GitHub releases through Sparkle. The feed (`appcast.xml`, an asset of
/// the latest release) and the EdDSA key that both it and each archive must be signed with are in
/// `Info.plist`; `.github/workflows/release.yml` publishes them. Sparkle asks on the second launch
/// whether to check automatically, and keeps that choice in its own user defaults.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// Only Release builds (`WOOLOO_UPDATES`) update themselves; a development build would otherwise
    /// offer, or install, the latest release over itself. Unit tests run inside the app, and
    /// `WOOLOO_DISABLE_UPDATES` keeps Sparkle's alerts out of measured runs.
    nonisolated static var isEnabled: Bool {
        #if WOOLOO_UPDATES
        return !WoolooApp.isHostingTests && ProcessInfo.processInfo.environment["WOOLOO_DISABLE_UPDATES"] == nil
        #else
        return false
        #endif
    }

    /// False until the updater starts, and while a check or an update is already under way.
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// Called once at launch; starts Sparkle's scheduled checks.
    func start() {
        guard Self.isEnabled else { return }
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
