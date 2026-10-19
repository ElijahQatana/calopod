import CalopodSnapshot
import CloudKit
import Foundation

/// Reads the snapshot the Mac publishes to the user's private iCloud database.
///
/// PENDING THE SCHEMA (#243): the zone name, record type and field names below are
/// placeholders. Only this file should change when the Mac side settles them.
struct CloudKitReader: SnapshotReader {
    static let containerID = "iCloud.pro.elijahquintana.calopod"
    private static let zoneName = "Snapshot"
    private static let kindField = "kind"
    private static let payloadField = "payload"

    func read() async throws -> SnapshotResult {
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

    private static func assemble(_ payloads: [(kind: String, data: Data)]) throws -> SnapshotResult {
        guard !payloads.isEmpty else { return .nothingPublished }
        do {
            var inbox: [InboxItem] = []
            var availability: [AvailabilityDay] = []
            var calendars: [CalendarEntry] = []
            var status = SyncStatus(lastSyncAt: nil)
            var publishedAt = Date.distantPast
            for (kind, data) in payloads {
                switch kind {
                case "inbox":
                    let item = try SnapshotCoding.decode(InboxItem.self, from: data)
                    inbox.append(item.record)
                    publishedAt = max(publishedAt, item.generatedAt)
                case "availability":
                    let day = try SnapshotCoding.decode(AvailabilityDay.self, from: data)
                    availability.append(day.record)
                    publishedAt = max(publishedAt, day.generatedAt)
                case "calendars":
                    let list = try SnapshotCoding.decode(CalendarList.self, from: data)
                    calendars = list.record.calendars
                    publishedAt = max(publishedAt, list.generatedAt)
                case "status":
                    let current = try SnapshotCoding.decode(SyncStatus.self, from: data)
                    status = current.record
                    publishedAt = max(publishedAt, current.generatedAt)
                default:
                    continue
                }
            }
            return .snapshot(Snapshot(
                publishedAt: publishedAt, inbox: inbox.sorted { $0.startsAt < $1.startsAt },
                availability: availability.sorted { $0.day < $1.day }, calendars: calendars, status: status))
        } catch SnapshotError.newerVersion {
            throw ReaderError.needsNewerApp
        }
    }
}
