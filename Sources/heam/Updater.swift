import AppKit
import Combine
import Sparkle

/// Sparkle updates. The feed and public key live in Info.plist; see scripts/release.sh for publishing.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    /// nil outside the app bundle (`--dump`, `--snapshot`, the fan helper), where Sparkle has nothing to update.
    static let shared: Updater? = Bundle.main.bundleIdentifier == nil ? nil : Updater()

    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController!
    private var observation: AnyCancellable?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        // A menu bar app is never frontmost; bring it forward so Sparkle's window isn't hidden.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // heam lives in the menu bar, so scheduled update alerts must not pop up behind other apps.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in NSApp.activate() }
    }
}
