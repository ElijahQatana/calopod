import CalopodSnapshot
import CloudKit
import Foundation

struct CloudKitSnapshotSharing: SnapshotSharing {
    private func container() async throws -> CKContainer {
        let container = CKContainer(identifier: SnapshotRemote.containerIdentifier)
        try await CloudKitSnapshotPublisher.requireAccount(container)
        return container
    }

    private func shareID(_ zone: String) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: CloudKitSnapshotPublisher.zoneID(zone))
    }

    private func existingShare(_ zone: String, in database: CKDatabase) async throws -> CKShare? {
        do {
            return try await database.record(for: shareID(zone)) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    func invite(email: String, inZone zone: String) async throws -> URL {
        do {
            let container = try await container()
            let database = container.privateCloudDatabase
            let participant = try await lookup(email, in: container)
            let share = try await existingShare(zone, in: database)
                ?? CKShare(recordZoneID: CloudKitSnapshotPublisher.zoneID(zone))
            share.publicPermission = .none
            share[CKShare.SystemFieldKey.title] = "Calopod"
            participant.permission = .readOnly
            share.addParticipant(participant)
            guard let url = (try await database.save(share) as? CKShare)?.url else {
                throw CloudKitSnapshotPublisher.Failure(errorDescription: "iCloud did not make a link for the invitation.")
            }
            return url
        } catch {
            throw CloudKitSnapshotPublisher.plain(error)
        }
    }

    func participants(inZone zone: String) async throws -> [SnapshotParticipant] {
        do {
            let database = try await container().privateCloudDatabase
            guard let share = try await existingShare(zone, in: database) else { return [] }
            return share.participants.filter { $0.role != .owner && $0.acceptanceStatus != .removed }.map {
                SnapshotParticipant(
                    id: $0.participantID, name: Self.name($0), status: $0.acceptanceStatus == .accepted ? .accepted : .invited)
            }
        } catch {
            throw CloudKitSnapshotPublisher.plain(error)
        }
    }

    func remove(_ participant: SnapshotParticipant, inZone zone: String) async throws {
        do {
            let database = try await container().privateCloudDatabase
            guard let share = try await existingShare(zone, in: database),
                let match = share.participants.first(where: { $0.participantID == participant.id })
            else { return }
            share.removeParticipant(match)
            _ = try await database.save(share)
        } catch {
            throw CloudKitSnapshotPublisher.plain(error)
        }
    }

    func stopSharing(inZone zone: String) async throws {
        do {
            _ = try await container().privateCloudDatabase.deleteRecord(withID: shareID(zone))
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return
        } catch {
            throw CloudKitSnapshotPublisher.plain(error)
        }
    }

    /// Fails when no Apple ID uses the address.
    private func lookup(_ email: String, in container: CKContainer) async throws -> CKShare.Participant {
        do {
            return try await container.shareParticipant(forEmailAddress: email)
        } catch let error as CKError where error.code == .unknownItem {
            throw CloudKitSnapshotPublisher.Failure(errorDescription: "iCloud has no Apple ID with that address.")
        }
    }

    private static func name(_ participant: CKShare.Participant) -> String {
        let identity = participant.userIdentity
        if let components = identity.nameComponents {
            let name = components.formatted()
            if !name.isEmpty { return name }
        }
        return identity.lookupInfo?.emailAddress ?? "Someone"
    }
}
