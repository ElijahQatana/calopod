import CalopodDomain
import CalopodStore
import CryptoKit
import Foundation

/// How confidently a target event is traced to Calopod. The planner only changes `.verified`
/// events; the rest become `.repair`.
public enum TargetOwnershipStatus: String, Codable, Equatable, Sendable {
    case verified
    case missingMarker = "missing-marker"
    case invalidMarker = "invalid-marker"
    case unknownConfiguration = "unknown-configuration"
    case unknownArm = "unknown-arm"
    case wrongTarget = "wrong-target"
    case unmanaged
}

/// An event on the target, classified by ownership by `ManagedTargetObserver`.
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
    public let providerExternalID: String?

    public init(
        calendarBindingID: String,
        providerEventID: String,
        providerVersion: String? = nil,
        mirrorKey: String?,
        contentFingerprint: String?,
        ownershipKeyID: String? = nil,
        ownershipStatus: TargetOwnershipStatus,
        createdAt: Date? = nil,
        isProviderPreferredIdentity: Bool = false,
        providerExternalID: String? = nil
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
        self.providerExternalID = providerExternalID
    }
}

/// Computes the diff between what the sources want and what the target has. It is pure, so dry-run
/// and apply share the same decisions.
public enum SyncPlanner {
    /// Reconciles one Arm in three passes, joined by `mirrorKey` (a stable hash of the Arm and
    /// source):
    /// 1. Each source event in the window: create, update, no-op or repair.
    /// 2. Mappings whose target is observed but whose source no longer wants a mirror: remove or
    ///    repair.
    /// 3. Leftover target events matching neither: flag orphans for repair.
    public static func plan(
        arm: StoredArm,
        targetProvider: ProviderKind? = nil,
        sources: [StoredNormalizedInstance],
        mappings: [StoredMirrorMapping],
        targetEvents: [TargetEventObservation],
        window: SyncWindow,
        sourceSnapshotComplete: Bool,
        targetSnapshotComplete: Bool = true,
        targetOriginals: [StoredNormalizedInstance] = []
    ) -> SyncPlan {
        let armSourceIDs = Set(arm.sourceBindingIDs)
        let inWindow = sources.filter {
            armSourceIDs.contains($0.calendarBindingID)
                && !$0.isCancelled
                && $0.endsAt > window.start
                && $0.startsAt < window.end
        }
        // A filtered event is planned like one that left the source.
        let boundedSources = inWindow.filter { arm.filters.copies($0) }
        let filteredMirrorKeys = Set(
            inWindow.filter { !arm.filters.copies($0) }.map {
                mirrorKey(armID: arm.id, sourceKeyHash: $0.sourceKeyHash)
            }
        )
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

        // Events already on the target (passed separately so a meeting invited to both calendars
        // isn't copied). Callers must only include calendars read in this run. A declined event
        // takes no time there, so it doesn't count.
        let originals = targetOriginals.filter {
            $0.calendarBindingID == arm.targetBindingID && !$0.isCancelled
                && $0.currentUserResponse.state != .declined
        }
        let targetEventKeys = Set(originals.compactMap(sameEventKey))
        let targetExternalIDs = Set(originals.compactMap { normalizedText($0.providerExternalID) })

        var items: [SyncPlanItem] = []
        var desiredMirrorKeys = Set<String>()

        // Pass 1: sources that should have a mirror, sorted so the plan doesn't depend on read
        // order.
        for source in boundedSources.sorted(by: sourceOrder) {
            let mirrorKey = mirrorKey(armID: arm.id, sourceKeyHash: source.sourceKeyHash)
            desiredMirrorKeys.insert(mirrorKey)
            let justBusy = arm.ruleMode == .fullDetails && EventTag.read(source).contains(.justBusy)
            let payload = desiredPayload(
                source: source,
                arm: arm,
                targetProvider: targetProvider,
                justBusy: justBusy
            )
            let fingerprint = desiredFingerprint(payload: payload, ruleMode: arm.ruleMode)
            let mapping = mappingsByMirror[mirrorKey]
            let observations = observationsByMirror[mirrorKey] ?? []
            let verified = observations.filter { $0.ownershipStatus == .verified }
            let unverified = observations.filter {
                $0.ownershipStatus != .verified && $0.ownershipStatus != .unmanaged
            }
            let originalOnTarget = targetHolds(
                source, eventKeys: targetEventKeys, externalIDs: targetExternalIDs
            )

            // Ownership comes first: an unverifiable event, or several verified ones for one
            // mirror, goes to `.repair`, never auto-resolved.
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
                } else if originalOnTarget {
                    // The target calendar already holds the invite itself; remove Calopod's copy.
                    action = .remove
                    reason = .targetHasOriginal
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
            } else if originalOnTarget {
                action = .noOp
                reason = .targetMatches
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

        // Pass 2: observed copies whose source no longer wants a mirror.
        for mapping in armMappings where !desiredMirrorKeys.contains(mapping.mirrorKey) {
            let observations = observationsByMirror[mapping.mirrorKey] ?? []
            // A bounded read cannot prove an unseen copy is missing.
            guard !observations.isEmpty else { continue }
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
                reason = filteredMirrorKeys.contains(mapping.mirrorKey) ? .filteredOut : .sourceMissing
            } else if verified.first != nil {
                action = .repair
                reason = .providerIdentityChanged
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

        // Pass 3: an `.unmanaged` event is someone else's and left alone; anything else carries a
        // marker we can't explain, which is worth flagging.
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

    /// Stable identity for "this source event, mirrored by this Arm", independent of provider IDs.
    /// It joins sources, mappings and target events, and is stored in the marker.
    public static func mirrorKey(armID: String, sourceKeyHash: String) -> String {
        base32(digest(fields: ["calopod-mirror-v1", armID, sourceKeyHash]))
    }

    /// Hash of everything the target fields derive from, for a Rule. Comparing it to the last
    /// written value tells a real change from a no-op.
    public static func desiredFingerprint(
        payload: DesiredEventPayload,
        ruleMode: ArmRuleMode
    ) -> String {
        // All-day events compare by calendar day, so a mirror read back in
        // the target calendar's zone still matches its source.
        let (start, end) = allDayIdentity(payload)
        return digestHex(
            fields: [
                "calopod-desired-v1",
                ruleMode.rawValue,
                start,
                end,
                payload.isAllDay ? "1" : "0",
                payload.availability,
                payload.title ?? "",
                payload.isPrivate.map { $0 ? "1" : "0" } ?? "",
                payload.location ?? "",
                payload.notes ?? "",
            ]
        )
    }

    /// True when the target calendar already holds this source event: same title and time, or the
    /// same server UID (`providerExternalID`, EventKit's calendarItemExternalIdentifier).
    private static func targetHolds(
        _ source: StoredNormalizedInstance,
        eventKeys: Set<String>,
        externalIDs: Set<String>
    ) -> Bool {
        if let key = sameEventKey(source), eventKeys.contains(key) {
            return true
        }
        if let externalID = normalizedText(source.providerExternalID),
           externalIDs.contains(externalID) {
            return true
        }
        return false
    }

    /// Title and time. All-day events compare by day, so other zones still match.
    private static func sameEventKey(_ event: StoredNormalizedInstance) -> String? {
        guard let title = normalizedText(event.title)?.lowercased() else { return nil }
        let (start, end) = event.isAllDay
            ? AllDayDate.days(startsAt: event.startsAt, endsAt: event.endsAt, timeZoneIdentifier: event.timeZoneIdentifier)
            : (dateIdentity(event.startsAt), dateIdentity(event.endsAt))
        return [title, start, end, event.isAllDay ? "1" : "0"].joined(separator: "\n")
    }

    private static func allDayIdentity(_ payload: DesiredEventPayload) -> (String, String) {
        guard payload.isAllDay else {
            return (dateIdentity(payload.startsAt), dateIdentity(payload.endsAt))
        }
        return AllDayDate.days(
            startsAt: payload.startsAt,
            endsAt: payload.endsAt,
            timeZoneIdentifier: payload.timeZoneIdentifier
        )
    }

    private static func desiredPayload(
        source: StoredNormalizedInstance,
        arm: StoredArm,
        targetProvider: ProviderKind?,
        justBusy: Bool
    ) -> DesiredEventPayload {
        switch justBusy ? .busy : arm.ruleMode {
        case .busy, .label:
            let span = arm.effectivePadding.padded(of: source)
            return DesiredEventPayload(
                startsAt: span.startsAt,
                endsAt: span.endsAt,
                isAllDay: source.isAllDay,
                availability: source.availability,
                title: arm.plainCopyTitle(isPrivate: source.isPrivate),
                isPrivate: nil,
                location: nil,
                notes: nil,
                timeZoneIdentifier: source.isAllDay ? source.timeZoneIdentifier : nil
            )
        case .fullDetails:
            return DesiredEventPayload(
                startsAt: source.startsAt,
                endsAt: source.endsAt,
                isAllDay: source.isAllDay,
                availability: source.availability,
                title: source.title,
                isPrivate: targetProvider == .eventKit ? nil : source.isPrivate,
                location: source.location,
                notes: fullDetailsNotes(source),
                timeZoneIdentifier: source.isAllDay ? source.timeZoneIdentifier : nil
            )
        }
    }

    /// Builds notes for Full details. EventKit's organizer and attendee fields are read-only and
    /// native attendee writes could send invitations, so people and the meeting link go in
    /// plain-text notes.
    private static func fullDetailsNotes(_ source: StoredNormalizedInstance) -> String? {
        var sections: [String] = []
        if let notes = normalizedNotes(source.notes) {
            sections.append(notes)
        }
        if let url = normalizedText(source.url),
           !sections.contains(where: { $0.contains(url) }) {
            sections.append("Link: \(url)")
        }
        let organizer = participantPresentation(source.organizer)
        if let organizer {
            sections.append("Organizer: \(organizer.summary)")
        }
        var participantKeys = Set(organizer.map { [$0.identityKey] } ?? [])
        let attendees = source.attendees
            .compactMap(participantPresentation)
            .filter { participantKeys.insert($0.identityKey).inserted }
            .map(\.summary)
            .sorted()
        if !attendees.isEmpty {
            sections.append("Attendees:\n" + attendees.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    private struct ParticipantPresentation {
        let identityKey: String
        let summary: String
    }

    private static func participantPresentation(
        _ participant: EventParticipant?
    ) -> ParticipantPresentation? {
        guard let participant else { return nil }
        let name = normalizedText(participant.name)
        let email = normalizedText(participant.emailAddress)
        guard name != nil || email != nil else { return nil }
        var identity: String
        switch (name, email) {
        case let (.some(name), .some(email)):
            identity = "\(name) <\(email)>"
        case let (.some(name), .none):
            identity = name
        case let (.none, .some(email)):
            identity = email
        case (.none, .none):
            return nil
        }
        if let status = participantStatus(participant.status) {
            identity += " (\(status))"
        }
        return ParticipantPresentation(
            identityKey: (email ?? name ?? "").lowercased(),
            summary: identity
        )
    }

    private static func participantStatus(_ value: String?) -> String? {
        guard let value = normalizedText(value) else { return nil }
        switch value.lowercased().replacingOccurrences(of: "_", with: "") {
        case "needsaction": return "needs action"
        case "notresponded": return "no response"
        case "none", "unknown": return nil
        default: return value
        }
    }

    private static func normalizedNotes(_ value: String?) -> String? {
        guard let value else { return nil }
        var lines = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var line = String(line)
                while line.last == " " || line.last == "\t" {
                    line.removeLast()
                }
                return line
            }
        while lines.first?.allSatisfy(\.isWhitespace) == true {
            lines.removeFirst()
        }
        while lines.last?.allSatisfy(\.isWhitespace) == true {
            lines.removeLast()
        }
        var normalized: [String] = []
        var previousWasBlank = false
        for line in lines {
            let isBlank = line.allSatisfy(\.isWhitespace)
            if !isBlank || !previousWasBlank {
                normalized.append(isBlank ? "" : line)
            }
            previousWasBlank = isBlank
        }
        return normalized.isEmpty ? nil : normalized.joined(separator: "\n")
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
