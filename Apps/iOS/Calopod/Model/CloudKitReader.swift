import CalopodSnapshot
import CloudKit
import Foundation

protocol ICloudAvailability: Sendable {
    var isSignedIn: Bool { get }
}

struct SystemICloud: ICloudAvailability {
    /// The identity token is nil with no iCloud account, and also when the build has no iCloud entitlement.
    var isSignedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }
}

/// Reads the snapshot the Mac publishes to the user's private iCloud database.
///
/// The names below match docs/iphone-feed.md on the Mac publisher's branch: one `Snapshot` record
/// per Inbox item, per day of busy time and per day of events, plus one each for the calendar list and sync status,
/// all in the `Snapshots` zone. They are copied, not shared, so keep them in step with the Mac.
struct CloudKitReader: SnapshotReader {
    var iCloud: ICloudAvailability = SystemICloud()

    static let containerID = "iCloud.pro.elijahquintana.calopod"
    private static let zoneName = "Snapshots"
    private static let kindField = "kind"
    private static let payloadField = "payload"

    func read() async throws -> SnapshotResult {
        // CKContainer traps when iCloud can't be used, so check before touching it.
        guard iCloud.isSignedIn else { throw ReaderError.signedOut }
        let database = CKContainer(identifier: Self.containerID).privateCloudDatabase
        let zone = CKRecordZone.ID(zoneName: Self.zoneName)
        let changes: [CKRecord]
        do {
            let result = try await database.recordZoneChanges(inZoneWith: zone, since: nil)
            changes = result.modificationResultsByID.values.compactMap { try? $0.get().record }
        } catch let error as CKError where error.code == .zoneNotFound {
            return .sharingOff
        } catch {
            throw ReaderError.unavailable
        }
        return try Self.assemble(changes.compactMap(Self.payload))
    }

    private static func payload(_ record: CKRecord) -> (kind: String, data: Data)? {
        guard let kind = record[kindField] as? String, let data = record[payloadField] as? Data else { return nil }
        return (kind, data)
    }

    static func assemble(_ payloads: [(kind: String, data: Data)]) throws -> SnapshotResult {
        guard !payloads.isEmpty else { return .nothingPublished }
        do {
            var inbox: [InboxItem] = []
            var availability: [AvailabilityDay] = []
            var days: [CalendarDay] = []
            var calendars: [CalendarEntry] = []
            var status = SyncStatus(lastSyncAt: nil)
            var publishedAt = Date.distantPast
            for (kind, data) in payloads {
                switch kind {
                case "inbox-item":
                    let item = try SnapshotCoding.decode(InboxItem.self, from: data)
                    inbox.append(item.record)
                    publishedAt = max(publishedAt, item.generatedAt)
                case "availability-day":
                    let day = try SnapshotCoding.decode(AvailabilityDay.self, from: data)
                    availability.append(day.record)
                    publishedAt = max(publishedAt, day.generatedAt)
                case "calendar-day":
                    let day = try SnapshotCoding.decode(CalendarDay.self, from: data)
                    days.append(day.record)
                    publishedAt = max(publishedAt, day.generatedAt)
                case "calendars":
                    let list = try SnapshotCoding.decode(CalendarList.self, from: data)
                    calendars = list.record.calendars
                    publishedAt = max(publishedAt, list.generatedAt)
                case "sync-status":
                    let current = try SnapshotCoding.decode(SyncStatus.self, from: data)
                    status = current.record
                    publishedAt = max(publishedAt, current.generatedAt)
                default:
                    continue
                }
            }
            return .snapshot(Snapshot(
                publishedAt: publishedAt, inbox: inbox.sorted { $0.startsAt < $1.startsAt },
                availability: availability.sorted { $0.day < $1.day },
                days: days.sorted { $0.day < $1.day }, calendars: calendars, status: status))
        } catch SnapshotError.newerVersion {
            throw ReaderError.needsNewerApp
        }
    }
}
