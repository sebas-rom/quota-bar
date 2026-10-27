import Foundation
import Sparkle
import SwiftUI

// MARK: - Updates
//
// Sparkle 2 with two channels. The feed is a single appcast served from the
// `appcast` release asset; nightly items carry <sparkle:channel>nightly</sparkle:channel>
// and are only offered when the user opts in.

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case nightly

    var id: String { rawValue }
    var title: String { self == .stable ? "Stable" : "Nightly" }
    var detail: String {
        self == .stable
            ? "Tagged releases only"
            : "Every build from main"
    }
}

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    private var controller: SPUStandardUpdaterController?
    private static let channelKey = "UpdateChannel"

    @Published private(set) var channel: UpdateChannel
    @Published var automaticChecks: Bool = false {
        didSet {
            controller?.updater.automaticallyChecksForUpdates = automaticChecks
        }
    }

    private override init() {
        channel = UpdateChannel(rawValue: UserDefaults.standard.string(forKey: Self.channelKey) ?? "") ?? .stable
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        automaticChecks = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setChannel(_ new: UpdateChannel) {
        guard new != channel else { return }
        channel = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.channelKey)
        // Re-evaluate on the next check without nagging immediately.
        controller?.updater.resetUpdateCycleAfterShortDelay()
    }

    // Sparkle asks which channels are allowed for this app.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel == .nightly ? ["nightly"] : []
    }
}
