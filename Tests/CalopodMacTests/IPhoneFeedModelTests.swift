import CalopodSnapshot
import CalopodStore
import Foundation
import Testing

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
@Suite("iPhone feed switch")
struct IPhoneFeedModelTests {
    private func model(
        _ availability: IPhoneFeedAvailability, remote: InMemorySnapshotPublisher,
        sharing: InMemorySnapshotSharing = InMemorySnapshotSharing()
    ) throws -> (IPhoneFeedModel, LocalStateRepository) {
        let fixture = try MacFixture(count: 1)
        let state = fixture.state
        try state.beginSyncRun(mode: "apply", trigger: "automatic", id: "run", now: fixture.now)
        try state.finishSyncRun(id: "run", status: "succeeded", now: fixture.now)
        let service = IPhoneFeedService(makeRepository: { state }, now: { fixture.now })
        return (IPhoneFeedModel(service: service, publisher: remote, sharing: sharing, availability: availability), state)
    }

    @Test("Turning it on uploads, turning it off deletes")
    func onAndOff() async throws {
        let remote = InMemorySnapshotPublisher()
        let (model, _) = try model(.available, remote: remote)
        await model.setOn(true)
        #expect(model.isOn && model.feed.publishedAt != nil)
        #expect(await remote.replaceCount == 1)
        await model.setOn(false)
        #expect(!model.isOn && !model.feed.removePending)
        #expect(await remote.zones.isEmpty)
    }

    @Test("A calendar starts unchosen and the choice is saved and uploaded")
    func choosingCalendars() async throws {
        let remote = InMemorySnapshotPublisher()
        let (model, state) = try model(.available, remote: remote)
        await model.setOn(true)
        let calendar = try #require(model.calendars.first)
        #expect(!calendar.isChosen && model.calendars.allSatisfy { !$0.isChosen })
        await model.setCalendar(calendar.id, chosen: true)
        #expect(model.calendars.first { $0.id == calendar.id }?.isChosen == true)
        #expect(try state.iPhoneCalendarIDs() == [calendar.id])
        #expect(await remote.replaceCount == 2)
    }

    @Test("Without an iCloud signature the switch stays off and iCloud is never called")
    func unavailable() async throws {
        let remote = InMemorySnapshotPublisher()
        let (model, _) = try model(.notSigned, remote: remote)
        await model.setOn(true)
        await model.tick()
        #expect(!model.isOn && model.problem == nil)
        #expect(await remote.replaceCount == 0)
    }

    @Test("A failed upload is reported and a later tick that is not due leaves it alone")
    func failureShows() async throws {
        let remote = InMemorySnapshotPublisher()
        await remote.setFailing(true)
        let (model, _) = try model(.available, remote: remote)
        await model.setOn(true)
        #expect(model.isOn)
        #expect(model.problem?.hasPrefix("The iPhone feed could not be uploaded.") == true)
        await model.tick()
        #expect(await remote.replaceCount == 0)
    }

    @Test("Inviting needs an uploaded feed, and a busy-only invite publishes the busy copy first")
    func inviting() async throws {
        let remote = InMemorySnapshotPublisher(), sharing = InMemorySnapshotSharing()
        let (model, state) = try model(.available, remote: remote, sharing: sharing)
        await #expect(throws: (any Error).self) { _ = try await model.invite(email: "a@example.com", level: .full) }
        await model.setOn(true)
        await #expect(throws: (any Error).self) { _ = try await model.invite(email: "not an address", level: .full) }

        let link = try await model.invite(email: "a@example.com", level: .busy)
        let zones = try state.iPhoneFeedZone()
        let busyZone = SnapshotRemote.zoneName(mac: zones.macID, level: .busy)
        #expect(link.absoluteString.hasSuffix(busyZone) && zones.busyShared)
        let busyRecords = await remote.records(inZone: busyZone)
        #expect(!busyRecords.isEmpty)
        #expect(model.people.map(\.level) == [.busy] && model.people.first?.person.name == "a@example.com")

        _ = try await model.invite(email: "b@example.com", level: .full)
        #expect(model.people.count == 2)
    }

    @Test("Removing one person keeps the others, and stopping the busy share deletes its copy")
    func stopping() async throws {
        let remote = InMemorySnapshotPublisher(), sharing = InMemorySnapshotSharing()
        let (model, state) = try model(.available, remote: remote, sharing: sharing)
        await model.setOn(true)
        _ = try await model.invite(email: "a@example.com", level: .full)
        _ = try await model.invite(email: "b@example.com", level: .full)
        await model.remove(try #require(model.people.first))
        #expect(model.people.map(\.person.name) == ["b@example.com"])

        _ = try await model.invite(email: "c@example.com", level: .busy)
        await model.stopSharing(.busy)
        #expect(model.people.map(\.level) == [.full])
        let remaining = await remote.zones.keys
        #expect(try state.iPhoneFeedZone().busyShared == false && !remaining.contains { $0.hasSuffix("-busy") })

        await model.stopSharing(.full)
        let kept = await remote.records
        #expect(model.people.isEmpty && !kept.isEmpty)
    }

    @Test("Turning the feed off clears the list of people")
    func offClearsPeople() async throws {
        let remote = InMemorySnapshotPublisher()
        let (model, _) = try model(.available, remote: remote)
        await model.setOn(true)
        _ = try await model.invite(email: "a@example.com", level: .full)
        await model.setOn(false)
        let zones = await remote.zones
        #expect(model.people.isEmpty && zones.isEmpty)
    }
}
