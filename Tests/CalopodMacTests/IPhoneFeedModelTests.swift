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
        _ availability: IPhoneFeedAvailability, remote: InMemorySnapshotPublisher
    ) throws -> (IPhoneFeedModel, LocalStateRepository) {
        let fixture = try MacFixture(count: 1)
        let state = fixture.state
        try state.beginSyncRun(mode: "apply", trigger: "automatic", id: "run", now: fixture.now)
        try state.finishSyncRun(id: "run", status: "succeeded", now: fixture.now)
        let service = IPhoneFeedService(makeRepository: { state }, now: { fixture.now })
        return (IPhoneFeedModel(service: service, publisher: remote, availability: availability), state)
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
}
