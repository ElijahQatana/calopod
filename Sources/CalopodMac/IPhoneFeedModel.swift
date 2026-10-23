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
    /// The calendars that can send events, with the choice made for each.
    private(set) var calendars: [IPhoneFeedService.CalendarChoice] = []
    private(set) var people: [SharedPerson] = []
    private(set) var shareProblem: String?
    let availability: IPhoneFeedAvailability

    @ObservationIgnored private let service: IPhoneFeedService
    @ObservationIgnored private let publisher: any SnapshotPublisher
    @ObservationIgnored private let sharing: any SnapshotSharing

    struct SharedPerson: Identifiable, Equatable {
        let person: SnapshotParticipant
        let level: SnapshotLevel
        var id: String { "\(level.rawValue)-\(person.id)" }
    }

    init(
        service: IPhoneFeedService = IPhoneFeedService(),
        publisher: any SnapshotPublisher = CloudKitSnapshotPublisher(),
        sharing: any SnapshotSharing = CloudKitSnapshotSharing(),
        availability: IPhoneFeedAvailability = .current
    ) {
        self.service = service
        self.publisher = publisher
        self.sharing = sharing
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
        if !on { people = [] }
    }

    /// Saves the choice, then uploads so the phone gets, or loses, that calendar's events.
    func setCalendar(_ id: String, chosen: Bool) async {
        _ = try? service.setCalendar(id, chosen: chosen)
        reload()
        await run(force: false)
    }

    func retry() async { await run(force: true) }

    // MARK: Sharing

    /// The busy-only zone is only asked about while it is published.
    func loadPeople() async {
        guard availability.isAvailable, feed.isEnabled, let zones = try? service.zones() else {
            people = []
            return
        }
        do {
            var found: [SharedPerson] = []
            for (level, zone) in [(SnapshotLevel.full, zones.full), (.busy, zones.busy)] {
                if level == .busy, (try? service.busyShared()) != true { continue }
                found += try await sharing.participants(inZone: zone).map { SharedPerson(person: $0, level: level) }
            }
            people = found
            shareProblem = nil
        } catch {
            shareProblem = Self.message(error)
        }
    }

    func invite(email: String, level: SnapshotLevel) async throws -> URL {
        let address = email.trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else { throw Self.problem("Enter the Apple ID email address of the person to invite.") }
        guard availability.isAvailable, feed.isEnabled, feed.publishedAt != nil else {
            throw Self.problem("Turn the feed on and let the first upload finish before inviting anyone.")
        }
        isBusy = true
        defer { isBusy = false }
        let zones = try service.zones()
        if level == .busy {
            guard case .published = await service.startBusyCopy(publisher: publisher) else {
                throw Self.problem("The busy-time copy could not be uploaded. Try again in a moment.")
            }
        }
        let url = try await sharing.invite(email: address, inZone: level == .full ? zones.full : zones.busy)
        reload()
        await loadPeople()
        return url
    }

    func remove(_ shared: SharedPerson) async {
        guard let zones = try? service.zones() else { return }
        do {
            try await sharing.remove(shared.person, inZone: shared.level == .full ? zones.full : zones.busy)
            shareProblem = nil
        } catch {
            shareProblem = Self.message(error)
        }
        await loadPeople()
    }

    /// The busy-only copy is deleted. The main copy stays for this Mac's own iPhone.
    func stopSharing(_ level: SnapshotLevel) async {
        isBusy = true
        defer { isBusy = false }
        do {
            switch level {
            case .full: try await sharing.stopSharing(inZone: try service.zones().full)
            case .busy: try await service.endBusyCopy(publisher: publisher)
            }
            shareProblem = nil
        } catch {
            shareProblem = Self.message(error)
        }
        await loadPeople()
    }

    private static func problem(_ text: String) -> Error { CloudKitSnapshotPublisher.Failure(errorDescription: text) }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func run(force: Bool) async {
        // Without the iCloud entitlement the call would stop the app, so it is never made.
        guard availability.isAvailable, !isBusy else { return }
        isBusy = true
        _ = await service.run(publisher: publisher, force: force)
        isBusy = false
        reload()
    }

    private func reload() {
        feed = (try? service.state()) ?? feed
        calendars = (try? service.calendarChoices()) ?? calendars
    }
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
