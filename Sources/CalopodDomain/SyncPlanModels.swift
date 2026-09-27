import Foundation

/// What `SyncPlanner` decided to do about one mirrored event. `repair` is
/// distinct from `create`/`update`/`remove`: it covers cases the planner
/// could not resolve with full confidence (see `SyncPlanReason`) and that
/// `ManagedEventLifecycleService` will only act on when the evidence is
/// unambiguous.
public enum SyncPlanAction: String, Codable, CaseIterable, Sendable {
    case create
    case update
    case remove
    case repair
    case noOp = "no-op"
}

/// Why a plan item got the action it did — the human-readable justification
/// behind every create/update/remove/repair, useful for diagnostics without
/// needing to expose the underlying event content.
public enum SyncPlanReason: String, Codable, Sendable {
    case targetMissing = "target-missing"
    case targetDiffers = "target-differs"
    case targetMatches = "target-matches"
    case sourceMissing = "source-missing"
    case verifiedDuplicates = "verified-duplicates"
    case mappingMissing = "mapping-missing"
    case providerIdentityChanged = "provider-identity-changed"
    case ownershipUnverified = "ownership-unverified"
    case sourceSnapshotIncomplete = "source-snapshot-incomplete"
    case targetSnapshotIncomplete = "target-snapshot-incomplete"
}

/// The fields a mirrored event should have on the target, already shaped by
/// the Arm's Rule (Busy strips everything but timing; Full details carries
/// title, location, and notes too).
public struct DesiredEventPayload: Codable, Equatable, Sendable {
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
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
        notes: String? = nil
    ) {
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
        self.availability = availability
        self.title = title
        self.isPrivate = isPrivate
        self.location = location
        self.notes = notes
    }
}

/// One decision from a `SyncPlan`: what to do for a single mirror, and the
/// evidence (`desiredFingerprint`, `payload`) needed to carry it out without
/// re-deriving it from the source again.
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
}

/// The full, deterministic set of decisions for one Arm over one window —
/// the output of `SyncPlanner.plan` and the input to
/// `ManagedEventLifecycleService.apply`.
public struct SyncPlan: Codable, Equatable, Sendable {
    public let window: SyncWindow
    public let items: [SyncPlanItem]

    public init(window: SyncWindow, items: [SyncPlanItem]) {
        self.window = window
        self.items = items
    }
}
