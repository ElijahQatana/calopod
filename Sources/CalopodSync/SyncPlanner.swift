import CalopodDomain
import CalopodStore
import CryptoKit
import Foundation

/// How confidently a target-calendar event can be traced back to Calopod.
/// `SyncPlanner` only ever creates, updates, or deletes an event whose
/// ownership is `.verified`; every other status means the planner cannot
/// prove the event is safe to touch, so it becomes a `.repair` decision
/// instead of a silent mutation.
public enum TargetOwnershipStatus: String, Codable, Equatable, Sendable {
    case verified
    case missingMarker = "missing-marker"
    case invalidMarker = "invalid-marker"
    case unknownConfiguration = "unknown-configuration"
    case unknownArm = "unknown-arm"
    case wrongTarget = "wrong-target"
    case unmanaged
}

/// One event as it currently exists on the target calendar, classified by
/// ownership. Produced by `ManagedTargetObserver` from a raw provider
/// snapshot, and consumed by `SyncPlanner` alongside the desired source
/// state to compute what (if anything) needs to change.
public struct TargetEventObservation: Codable, Equatable, Sendable {
    public let calendarBindingID: String
    public let providerEventID: String
    public let providerVersion: String?
    public let mirrorKey: String?
    public let contentFingerprint: String?
    public let ownershipKeyID: String?
    public let ownershipStatus: TargetOwnershipStatus
    public let createdAt: Date?
    public let isProviderPreferredIdentity: Bool

    public init(
        calendarBindingID: String,
        providerEventID: String,
        providerVersion: String? = nil,
        mirrorKey: String?,
        contentFingerprint: String?,
        ownershipKeyID: String? = nil,
        ownershipStatus: TargetOwnershipStatus,
        createdAt: Date? = nil,
        isProviderPreferredIdentity: Bool = false
    ) {
        self.calendarBindingID = calendarBindingID
        self.providerEventID = providerEventID
        self.providerVersion = providerVersion
        self.mirrorKey = mirrorKey
        self.contentFingerprint = contentFingerprint
        self.ownershipKeyID = ownershipKeyID
        self.ownershipStatus = ownershipStatus
        self.createdAt = createdAt
        self.isProviderPreferredIdentity = isProviderPreferredIdentity
    }
}

/// Computes the deterministic diff between what an Arm's sources say should
/// exist on the target calendar and what is actually observed there. The
/// result is a pure, side-effect-free `SyncPlan`; nothing here talks to a
/// calendar provider, which is what makes dry-run and apply share the exact
/// same decision logic.
public enum SyncPlanner {
    /// Three-way reconciliation, one arm at a time:
    ///
    /// 1. Walk every source event that belongs in the window and decide
    ///    create / update / no-op / repair for its mirror.
    /// 2. Walk every mapping this Arm already owns whose source disappeared
    ///    (fell out of the window or was cancelled) and decide remove/repair.
    /// 3. Walk any leftover target observations that match neither a desired
    ///    source nor a known mapping, flagging genuinely orphaned events for
    ///    repair.
    ///
    /// A `mirrorKey` (a stable hash of the Arm and source identity) is the
    /// join key across all three passes, so this never depends on iteration
    /// order or provider-assigned IDs remaining stable.
    public static func plan(
        arm: StoredArm,
        targetProvider: ProviderKind? = nil,
        sources: [StoredNormalizedInstance],
        mappings: [StoredMirrorMapping],
        targetEvents: [TargetEventObservation],
        window: SyncWindow,
        sourceSnapshotComplete: Bool,
        targetSnapshotComplete: Bool = true
    ) -> SyncPlan {
        let armSourceIDs = Set(arm.sourceBindingIDs)
        let boundedSources = sources.filter {
            armSourceIDs.contains($0.calendarBindingID)
                && !$0.isCancelled
                && $0.endsAt > window.start
                && $0.startsAt < window.end
        }
        let armMappings = mappings.filter { $0.armID == arm.id }
        let targetObservations = targetEvents.filter {
            $0.calendarBindingID == arm.targetBindingID
        }
        let mappingsByMirror = Dictionary(
            armMappings.map { ($0.mirrorKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let observationsByMirror = Dictionary(
            grouping: targetObservations.compactMap { observation in
                observation.mirrorKey.map { ($0, observation) }
            },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }

        var items: [SyncPlanItem] = []
        var desiredMirrorKeys = Set<String>()

        // Pass 1: every source event that should have a mirror on the
        // target. Sorted deterministically so the resulting plan (and its
        // item IDs) don't depend on the order sources came back in.
        for source in boundedSources.sorted(by: sourceOrder) {
            let mirrorKey = mirrorKey(armID: arm.id, sourceKeyHash: source.sourceKeyHash)
            desiredMirrorKeys.insert(mirrorKey)
            let payload = desiredPayload(
                source: source,
                ruleMode: arm.ruleMode,
                targetProvider: targetProvider
            )
            let fingerprint = desiredFingerprint(payload: payload, ruleMode: arm.ruleMode)
            let mapping = mappingsByMirror[mirrorKey]
            let observations = observationsByMirror[mirrorKey] ?? []
            let verified = observations.filter { $0.ownershipStatus == .verified }
            let unverified = observations.filter {
                $0.ownershipStatus != .verified && $0.ownershipStatus != .unmanaged
            }

            // Ownership questions always come first: an event Calopod can't
            // positively verify, or more than one verified event for the
            // same mirror, is never auto-resolved here — it goes to `.repair`
            // so a human (or a later, narrower rule) decides what happens.
            let action: SyncPlanAction
            let reason: SyncPlanReason
            if !unverified.isEmpty {
                action = .repair
                reason = .ownershipUnverified
            } else if verified.count > 1 {
                action = .repair
                reason = .verifiedDuplicates
            } else if let target = verified.first {
                guard let mapping else {
                    items.append(
                        item(
                            armID: arm.id,
                            mirrorKey: mirrorKey,
                            sourceKeyHash: source.sourceKeyHash,
                            action: .repair,
                            reason: .mappingMissing,
                            desiredFingerprint: fingerprint,
                            payload: payload
                        )
                    )
                    continue
                }
                if target.providerEventID != mapping.providerEventID {
                    action = .repair
                    reason = .providerIdentityChanged
                } else if target.contentFingerprint == fingerprint {
                    action = .noOp
                    reason = .targetMatches
                } else {
                    action = .update
                    reason = .targetDiffers
                }
            } else if mapping != nil {
                action = .repair
                reason = targetSnapshotComplete ? .targetMissing : .targetSnapshotIncomplete
            } else if !targetSnapshotComplete {
                action = .repair
                reason = .targetSnapshotIncomplete
            } else {
                action = .create
                reason = .targetMissing
            }
            items.append(
                item(
                    armID: arm.id,
                    mirrorKey: mirrorKey,
                    sourceKeyHash: source.sourceKeyHash,
                    action: action,
                    reason: reason,
                    desiredFingerprint: fingerprint,
                    payload: payload
                )
            )
        }

        // Pass 2: mappings this Arm already owns whose source no longer
        // wants a mirror (it left the window or was cancelled). These are
        // candidates for `.remove`, but only once ownership on the target
        // side is unambiguous — the same caution as pass 1 applies.
        for mapping in armMappings where !desiredMirrorKeys.contains(mapping.mirrorKey) {
            let observations = observationsByMirror[mapping.mirrorKey] ?? []
            let verified = observations.filter { $0.ownershipStatus == .verified }
            let action: SyncPlanAction
            let reason: SyncPlanReason
            if !sourceSnapshotComplete {
                action = .repair
                reason = .sourceSnapshotIncomplete
            } else if observations.contains(where: {
                $0.ownershipStatus != .verified && $0.ownershipStatus != .unmanaged
            }) {
                action = .repair
                reason = .ownershipUnverified
            } else if verified.count > 1 {
                action = .repair
                reason = .verifiedDuplicates
            } else if let target = verified.first,
                      target.providerEventID == mapping.providerEventID {
                action = .remove
                reason = .sourceMissing
            } else if verified.first != nil {
                action = .repair
                reason = .providerIdentityChanged
            } else if targetSnapshotComplete && observations.isEmpty {
                action = .repair
                reason = .targetMissing
            } else if !targetSnapshotComplete {
                action = .repair
                reason = .targetSnapshotIncomplete
            } else {
                action = .repair
                reason = .ownershipUnverified
            }
            items.append(
                item(
                    armID: arm.id,
                    mirrorKey: mapping.mirrorKey,
                    sourceKeyHash: mapping.sourceKeyHash,
                    action: action,
                    reason: reason,
                    desiredFingerprint: nil,
                    payload: nil
                )
            )
        }

        // Pass 3: target events that match neither a desired source (pass 1)
        // nor a mapping this Arm knows about (pass 2). An `.unmanaged` event
        // is just someone else's calendar entry and is left alone; anything
        // else carries a Calopod marker Calopod can no longer explain, which
        // is always worth flagging.
        let mappedMirrorKeys = Set(armMappings.map(\.mirrorKey))
        for (mirrorKey, observations) in observationsByMirror
            where !desiredMirrorKeys.contains(mirrorKey) && !mappedMirrorKeys.contains(mirrorKey) {
            let reportable = observations.contains { $0.ownershipStatus != .unmanaged }
            guard reportable else { continue }
            items.append(
                item(
                    armID: arm.id,
                    mirrorKey: mirrorKey,
                    sourceKeyHash: nil,
                    action: .repair,
                    reason: .mappingMissing,
                    desiredFingerprint: nil,
                    payload: nil
                )
            )
        }

        return SyncPlan(
            window: window,
            items: items.sorted {
                ($0.armID, $0.mirrorKey, $0.action.rawValue)
                    < ($1.armID, $1.mirrorKey, $1.action.rawValue)
            }
        )
    }

    /// Stable identity for "this source event, mirrored by this Arm" that
    /// never depends on a provider-assigned event ID. Used as the join key
    /// between sources, mappings, and target observations, and stored in the
    /// ownership marker written onto every managed event so it can be
    /// re-derived and checked later.
    public static func mirrorKey(armID: String, sourceKeyHash: String) -> String {
        base32(digest(fields: ["calopod-mirror-v1", armID, sourceKeyHash]))
    }

    /// Hash of everything the target event's fields are derived from for a
    /// given Rule. Comparing this against the fingerprint recorded the last
    /// time Calopod wrote the event is how the planner tells a real content
    /// change apart from a no-op, without re-reading or diffing every field.
    public static func desiredFingerprint(
        payload: DesiredEventPayload,
        ruleMode: ArmRuleMode
    ) -> String {
        digestHex(
            fields: [
                "calopod-desired-v1",
                ruleMode.rawValue,
                dateIdentity(payload.startsAt),
                dateIdentity(payload.endsAt),
                payload.isAllDay ? "1" : "0",
                payload.availability,
                payload.title ?? "",
                payload.isPrivate.map { $0 ? "1" : "0" } ?? "",
                payload.location ?? "",
                payload.notes ?? "",
            ]
        )
    }

    private static func desiredPayload(
        source: StoredNormalizedInstance,
        ruleMode: ArmRuleMode,
        targetProvider: ProviderKind?
    ) -> DesiredEventPayload {
        switch ruleMode {
        case .busy:
            DesiredEventPayload(
                startsAt: source.startsAt,
                endsAt: source.endsAt,
                isAllDay: source.isAllDay,
                availability: source.availability,
                title: "Busy",
                isPrivate: nil,
                location: nil,
                notes: nil
            )
        case .fullDetails:
            DesiredEventPayload(
                startsAt: source.startsAt,
                endsAt: source.endsAt,
                isAllDay: source.isAllDay,
                availability: source.availability,
                title: source.title,
                isPrivate: targetProvider == .eventKit ? nil : source.isPrivate,
                location: source.location,
                notes: fullDetailsNotes(source)
            )
        }
    }

    /// Builds the notes field for a Full details Rule. EventKit's organizer
    /// and attendee fields are read-only and native attendee writes could
    /// send real invitations or RSVP changes, so participant context and the
    /// source's meeting link are folded into plain text notes instead of
    /// structured calendar fields.
    private static func fullDetailsNotes(_ source: StoredNormalizedInstance) -> String? {
        var sections: [String] = []
        if let notes = normalizedText(source.notes) {
            sections.append(notes)
        }
        if let url = normalizedText(source.url),
           !sections.contains(where: { $0.contains(url) }) {
            sections.append("Link: \(url)")
        }
        if let organizer = participantSummary(source.organizer) {
            sections.append("Organizer: \(organizer)")
        }
        let attendees = source.attendees.compactMap(participantSummary).sorted()
        if !attendees.isEmpty {
            sections.append("Attendees:\n" + attendees.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    private static func participantSummary(_ participant: EventParticipant?) -> String? {
        guard let participant else { return nil }
        let name = normalizedText(participant.name)
        let email = normalizedText(participant.emailAddress)
        var identity: String
        switch (name, email) {
        case let (.some(name), .some(email)):
            identity = "\(name) <\(email)>"
        case let (.some(name), .none):
            identity = name
        case let (.none, .some(email)):
            identity = email
        case (.none, .none):
            identity = "Unknown"
        }
        if let status = normalizedText(participant.status) {
            identity += " (\(status))"
        }
        return identity
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func item(
        armID: String,
        mirrorKey: String,
        sourceKeyHash: String?,
        action: SyncPlanAction,
        reason: SyncPlanReason,
        desiredFingerprint: String?,
        payload: DesiredEventPayload?
    ) -> SyncPlanItem {
        SyncPlanItem(
            id: digestHex(
                fields: [
                    "calopod-operation-v1",
                    action.rawValue,
                    mirrorKey,
                    desiredFingerprint ?? "",
                ]
            ),
            armID: armID,
            mirrorKey: mirrorKey,
            sourceKeyHash: sourceKeyHash,
            action: action,
            reason: reason,
            desiredFingerprint: desiredFingerprint,
            payload: payload
        )
    }

    private static func sourceOrder(
        _ left: StoredNormalizedInstance,
        _ right: StoredNormalizedInstance
    ) -> Bool {
        (left.startsAt, left.endsAt, left.sourceKeyHash)
            < (right.startsAt, right.endsAt, right.sourceKeyHash)
    }

    private static func dateIdentity(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate.bitPattern)
    }

    private static func digest(fields: [String]) -> SHA256.Digest {
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(value.utf8))
    }

    private static func digestHex(fields: [String]) -> String {
        digest(fields: fields).map { String(format: "%02x", $0) }.joined()
    }

    private static func base32(_ digest: SHA256.Digest) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var result = ""
        var buffer: UInt32 = 0
        var bitCount = 0

        for byte in digest {
            buffer = (buffer << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                result.append(alphabet[Int((buffer >> UInt32(bitCount)) & 31)])
            }
            if bitCount == 0 {
                buffer = 0
            } else {
                buffer &= (1 << UInt32(bitCount)) - 1
            }
        }
        if bitCount > 0 {
            result.append(alphabet[Int((buffer << UInt32(5 - bitCount)) & 31)])
        }
        return result
    }
}
