import Foundation

/// What the planner decided for one mirrored event. `repair` covers cases it could not resolve with
/// confidence; they are only acted on when the evidence is unambiguous.
public enum SyncPlanAction: String, Codable, CaseIterable, Sendable {
    case create
    case update
    case remove
    case repair
    case noOp = "no-op"
}

/// Why a plan item got its action. Safe to show because it carries no event content.
public enum SyncPlanReason: String, Codable, Sendable {
    case targetMissing = "target-missing"
    case targetDiffers = "target-differs"
    case targetMatches = "target-matches"
    case targetHasOriginal = "target-has-original"
    case sourceMissing = "source-missing"
    case filteredOut = "filtered-out"
    case taggedDontClone = "tagged-dont-clone"
    case taggedJustBusy = "tagged-just-busy"
    case privateEvent = "private-event"
    case markedFree = "marked-free"
    case workingLocation = "working-location"
    case birthday
    case verifiedDuplicates = "verified-duplicates"
    case mappingMissing = "mapping-missing"
    case providerIdentityChanged = "provider-identity-changed"
    case ownershipUnverified = "ownership-unverified"
    case sourceSnapshotIncomplete = "source-snapshot-incomplete"
    case targetSnapshotIncomplete = "target-snapshot-incomplete"
}

/// The fields a mirrored event should have on the target, already shaped by the Arm's Rule.
public struct DesiredEventPayload: Codable, Equatable, Sendable {
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
    /// Zone the all-day dates were read in. Only set for all-day events.
    public let timeZoneIdentifier: String?
    public let availability: String
    public let title: String?
    public let isPrivate: Bool?
    public let location: String?
    public let notes: String?

    public init(
        startsAt: Date,
        endsAt: Date,
        isAllDay: Bool,
        availability: String,
        title: String?,
        isPrivate: Bool?,
        location: String? = nil,
        notes: String? = nil,
        timeZoneIdentifier: String? = nil
    ) {
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.availability = availability
        self.title = title
        self.isPrivate = isPrivate
        self.location = location
        self.notes = notes
    }
}

/// One decision from a plan: the action for a single mirror and the evidence to carry it out.
public struct SyncPlanItem: Codable, Equatable, Sendable {
    public let id: String
    public let armID: String
    public let mirrorKey: String
    public let sourceKeyHash: String?
    public let action: SyncPlanAction
    public let reason: SyncPlanReason
    public let desiredFingerprint: String?
    public let payload: DesiredEventPayload?

    public init(
        id: String,
        armID: String,
        mirrorKey: String,
        sourceKeyHash: String?,
        action: SyncPlanAction,
        reason: SyncPlanReason,
        desiredFingerprint: String?,
        payload: DesiredEventPayload?
    ) {
        self.id = id
        self.armID = armID
        self.mirrorKey = mirrorKey
        self.sourceKeyHash = sourceKeyHash
        self.action = action
        self.reason = reason
        self.desiredFingerprint = desiredFingerprint
        self.payload = payload
    }

    /// The target was not fully read, so nothing is known about this copy. Never written.
    public var isUnchecked: Bool { action == .repair && reason == .targetSnapshotIncomplete }

    public static let uncheckedExplanation =
        "Calopod could not read the target calendars, so it cannot tell what needs repairing. Nothing will be changed until they are read."
}

/// All decisions for one Arm over one window. Output of `SyncPlanner.plan`, input to
/// `ManagedEventLifecycleService.apply`.
public struct SyncPlan: Codable, Equatable, Sendable {
    public let window: SyncWindow
    public let items: [SyncPlanItem]

    public init(window: SyncWindow, items: [SyncPlanItem]) {
        self.window = window
        self.items = items
    }
}

extension SyncPlan {
    /// Changes still to make. Copies left alone and copies whose target was not read are not counted.
    public var waitingCount: Int {
        items.filter { $0.action != .noOp && !$0.isUnchecked }.count
    }
}
