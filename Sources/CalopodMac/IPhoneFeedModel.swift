import CalopodCommands
import CalopodSnapshot
import CalopodStore
import Foundation
import Observation
import SwiftUI

/// The iPhone feed switch and its upload. Publishing runs here, in the app, because only the signed
/// app can reach iCloud. A failed upload is shown and tried again later; it never touches syncing.
@MainActor
@Observable
final class IPhoneFeedModel {
    private(set) var feed = StoredIPhoneFeed()
    private(set) var isBusy = false
    let availability: IPhoneFeedAvailability

    @ObservationIgnored private let service: IPhoneFeedService
    @ObservationIgnored private let publisher: any SnapshotPublisher

    init(
        service: IPhoneFeedService = IPhoneFeedService(),
        publisher: any SnapshotPublisher = CloudKitSnapshotPublisher(),
        availability: IPhoneFeedAvailability = .current
    ) {
        self.service = service
        self.publisher = publisher
        self.availability = availability
    }

    var isOn: Bool { feed.isEnabled }

    /// The last upload's problem, for the sync card and Settings. Nil when there is none.
    var problem: String? {
        guard availability.isAvailable, feed.isEnabled || feed.removePending, let failure = feed.failure else { return nil }
        return "The iPhone feed could not be uploaded. \(failure)"
    }

    /// Reads the saved setting, which the command line may have changed, and does whatever is due.
    func tick() async {
        reload()
        await run(force: false)
    }

    func setOn(_ on: Bool) async {
        guard availability.isAvailable || !on else { return }
        try? service.setEnabled(on)
        reload()
        await run(force: true)
    }

    func retry() async { await run(force: true) }

    private func run(force: Bool) async {
        // Without the iCloud entitlement the call would stop the app, so it is never made.
        guard availability.isAvailable, !isBusy else { return }
        isBusy = true
        _ = await service.run(publisher: publisher, force: force)
        isBusy = false
        reload()
    }

    private func reload() { feed = (try? service.state()) ?? feed }
}

private struct IPhoneFeedKey: EnvironmentKey {
    static let defaultValue: IPhoneFeedModel? = nil
}

extension EnvironmentValues {
    var iPhoneFeed: IPhoneFeedModel? {
        get { self[IPhoneFeedKey.self] }
        set { self[IPhoneFeedKey.self] = newValue }
    }
}
