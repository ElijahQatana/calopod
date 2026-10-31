import CalopodStore
import Foundation

/// One Arm's sync health as `arm list`, `doctor` and the Mac app show it.
public struct ArmSyncStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case neverSynced = "never-synced"
        case disabled
        case ok
        case failing
    }

    public let state: State
    public let lastSyncAt: Date?
    public let errorCategory: String?
    public let waiting: Int?

    init(state: State, lastSyncAt: Date?, errorCategory: String?, waiting: Int?) {
        self.state = state
        self.lastSyncAt = lastSyncAt
        self.errorCategory = errorCategory
        self.waiting = waiting
    }

    public init(arm: StoredArm, health: StoredArmSyncHealth?) {
        lastSyncAt = health?.lastSuccessAt
        errorCategory = health?.lastError.map(genericFailureCategory)
        waiting = health?.waiting
        if !arm.isEnabled {
            state = .disabled
        } else if errorCategory != nil {
            state = .failing
        } else if lastSyncAt == nil {
            state = .neverSynced
        } else {
            state = .ok
        }
    }

    public func line(now: Date = Date()) -> String {
        switch state {
        case .disabled: return "Disabled"
        case .neverSynced: return "Not synced yet"
        case .ok, .failing:
            let synced = state == .ok ? "Synced" : "Last synced"
            var parts = [lastSyncAt.map { "\(synced) \(Self.ago(from: $0, to: now))" } ?? "Never synced successfully"]
            if let errorCategory { parts.append("last error: \(FailureStep.description(for: errorCategory))") }
            if let waiting { parts.append(waiting == 0 ? "nothing waiting" : "\(waiting) \(waiting == 1 ? "change" : "changes") waiting") }
            return parts.joined(separator: ", ")
        }
    }

    private static func ago(from date: Date, to now: Date) -> String {
        FailureStep.ago(max(0, Int(now.timeIntervalSince(date)))) + " ago"
    }
}

extension CommandItem {
    /// The status an Arm item was written with, for the human view.
    var syncStatus: ArmSyncStatus? {
        guard let state = syncState.flatMap(ArmSyncStatus.State.init(rawValue:)) else { return nil }
        return ArmSyncStatus(
            state: state, lastSyncAt: lastSyncAt.flatMap { ISO8601DateFormatter().date(from: $0) },
            errorCategory: lastError, waiting: waiting)
    }
}
