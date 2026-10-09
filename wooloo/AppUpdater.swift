import Combine
import Sparkle

/// Updates wooloo from its GitHub releases through Sparkle. The feed (`appcast.xml`, an asset of
/// the latest release) and the EdDSA key that both it and each archive must be signed with are in
/// `Info.plist`; `.github/workflows/release.yml` publishes them. Sparkle asks on the second launch
/// whether to check automatically, and keeps that choice in its own user defaults.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// False while a check or an update is already under way.
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController

    private init() {
        // Unit tests run inside the app; they must not check for or install updates.
        controller = SPUStandardUpdaterController(startingUpdater: !WoolooApp.isHostingTests,
                                                  updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
