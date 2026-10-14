import AppKit
import Combine
import Observation
import Sparkle

/// Sparkle updates from the feed in Info.plist (SUFeedURL). Updates must be signed with the
/// EdDSA key in the release Mac's keychain (account "shortvid"); see Tools/release.sh.
@MainActor @Observable
final class AppUpdater: NSObject {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var cancellable: AnyCancellable?

    private(set) var canCheckForUpdates = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
