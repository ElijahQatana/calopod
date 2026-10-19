import CalopodSnapshot
import CloudKit
import Foundation

/// Uploads the iPhone feed to the private CloudKit database. This only works in the signed app: the
/// iCloud entitlement belongs to the main executable, so nothing else may call it. Calopod never
/// reads anyone else's iCloud and writes nothing here but the one `Snapshot` record type.
struct CloudKitSnapshotPublisher: SnapshotPublisher {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private static let batchSize = 300

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: SnapshotRemote.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    func replaceAll(with records: [SnapshotPayload]) async throws {
        do {
            let container = CKContainer(identifier: SnapshotRemote.containerIdentifier)
            try await requireAccount(container)
            let database = container.privateCloudDatabase
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            let wanted = Set(records.map(\.recordName))
            let stale = try await existingNames(in: database).filter { !wanted.contains($0) }
            let saving = records.map(record)
            for start in stride(from: 0, to: max(saving.count, 1), by: Self.batchSize) {
                let batch = Array(saving[start..<min(start + Self.batchSize, saving.count)])
                _ = try await database.modifyRecords(
                    saving: batch, deleting: start == 0 ? stale.map(recordID) : [], savePolicy: .allKeys)
            }
        } catch {
            throw Self.plain(error)
        }
    }

    func deleteAll() async throws {
        do {
            let container = CKContainer(identifier: SnapshotRemote.containerIdentifier)
            try await requireAccount(container)
            _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            return
        } catch {
            throw Self.plain(error)
        }
    }

    // MARK: Helpers

    private func requireAccount(_ container: CKContainer) async throws {
        guard try await container.accountStatus() == .available else {
            throw Failure(errorDescription: "iCloud is not signed in on this Mac.")
        }
    }

    /// Reads the zone's changes from the start, which lists every record without needing a query index.
    private func existingNames(in database: CKDatabase) async throws -> [String] {
        var names: Set<String> = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            names.formUnion(changes.modificationResultsByID.keys.map(\.recordName))
            names.subtract(changes.deletions.map(\.recordID.recordName))
            token = changes.changeToken
            more = changes.moreComing
        }
        return names.sorted()
    }

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    private func record(_ payload: SnapshotPayload) -> CKRecord {
        let record = CKRecord(recordType: SnapshotRemote.recordType, recordID: recordID(payload.recordName))
        record[SnapshotRemote.Field.kind] = payload.kind.rawValue
        record[SnapshotRemote.Field.schemaVersion] = payload.schemaVersion
        record[SnapshotRemote.Field.publishedAt] = payload.publishedAt
        record[SnapshotRemote.Field.payload] = payload.bytes
        return record
    }

    /// Short plain words for the errors people can act on. CloudKit's own text can be long and technical.
    static func plain(_ error: Error) -> Error {
        guard let error = error as? CKError else { return error }
        let text: String
        switch error.code {
        case .notAuthenticated: text = "iCloud is not signed in on this Mac."
        case .networkUnavailable, .networkFailure: text = "iCloud could not be reached."
        case .quotaExceeded: text = "The iCloud storage is full."
        case .missingEntitlement: text = "This copy of the app is not allowed to use iCloud."
        case .permissionFailure: text = "iCloud refused the upload."
        case .requestRateLimited, .serviceUnavailable, .zoneBusy: text = "iCloud is busy. It will be tried again."
        default: text = "iCloud returned an error (\(error.code.rawValue))."
        }
        return Failure(errorDescription: text)
    }
}
