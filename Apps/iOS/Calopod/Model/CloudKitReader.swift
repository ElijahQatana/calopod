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

/// Reads the feeds in this phone's iCloud and any shared with it.
///
/// The names below match docs/iphone-feed.md on the Mac publisher's branch: one `Snapshot` record
/// per Inbox item, per day of busy time and per day of events, plus one each for the calendar list, reminder settings and sync status,
/// in a zone per Mac. They are copied, not shared, so keep them in step with the Mac.
struct CloudKitReader: SnapshotReader {
    var iCloud: ICloudAvailability = SystemICloud()
    var selection = FeedSelection.standard

    static let containerID = SnapshotRemote.containerIdentifier
    private static let kindField = SnapshotRemote.Field.kind
    private static let payloadField = SnapshotRemote.Field.payload

    func read() async throws -> SnapshotResult {
        // CKContainer traps when iCloud can't be used, so check before touching it.
        guard iCloud.isSignedIn else { throw ReaderError.signedOut }
        let container = CKContainer(identifier: Self.containerID)
        var found: [(feed: Feed, snapshot: Snapshot)] = []
        var zoneCount = 0
        var needsNewerApp = false
        for (database, shared) in [(container.privateCloudDatabase, false), (container.sharedCloudDatabase, true)] {
            let zones: [CKRecordZone]
            do { zones = try await database.allRecordZones() } catch { throw ReaderError.unavailable }
            for zone in zones {
                guard let kind = SnapshotRemote.feed(inZone: zone.zoneID.zoneName) else { continue }
                zoneCount += 1
                let records: [CKRecord]
                do {
                    let result = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: nil)
                    records = result.modificationResultsByID.values.compactMap { try? $0.get().record }
                } catch { throw ReaderError.unavailable }
                do {
                    guard case .snapshot(let snapshot) = try Self.assemble(records.compactMap(Self.payload)) else { continue }
                    let feed = Feed(
                        id: "\(shared ? "shared" : "private"):\(zone.zoneID.ownerName):\(zone.zoneID.zoneName)",
                        name: snapshot.status.macName ?? "Mac", isShared: shared, level: kind.level,
                        publishedAt: snapshot.publishedAt)
                    found.append((feed, snapshot))
                } catch ReaderError.needsNewerApp {
                    needsNewerApp = true
                }
            }
        }
        return try Self.choose(found, zoneCount: zoneCount, needsNewerApp: needsNewerApp, preferred: selection.preferred)
    }

    static func choose(
        _ found: [(feed: Feed, snapshot: Snapshot)], zoneCount: Int, needsNewerApp: Bool, preferred: String?
    ) throws -> SnapshotResult {
        let feeds = FeedChoice.ordered(found.map(\.feed))
        guard let chosen = FeedChoice.pick(feeds, preferred: preferred),
            var snapshot = found.first(where: { $0.feed.id == chosen.id })?.snapshot
        else {
            if needsNewerApp { throw ReaderError.needsNewerApp }
            return zoneCount == 0 ? .sharingOff : .nothingPublished
        }
        snapshot.feed = chosen
        snapshot.feeds = feeds
        return .snapshot(snapshot)
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
            var reminders: ReminderSettings?
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
                case "reminder-settings":
                    let settings = try SnapshotCoding.decode(ReminderSettings.self, from: data)
                    reminders = settings.record
                    publishedAt = max(publishedAt, settings.generatedAt)
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
                days: days.sorted { $0.day < $1.day }, reminders: reminders, calendars: calendars, status: status))
        } catch SnapshotError.newerVersion {
            throw ReaderError.needsNewerApp
        }
    }
}
