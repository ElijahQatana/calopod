/// What an Arm may put on its target. `busy` is timing only; `fullDetails` (Main calendar) adds
/// title, location and notes.
public enum ArmRuleMode: String, CaseIterable, Codable, Sendable {
    case busy
    case fullDetails = "full-details"
}

/// Events an Arm leaves out. All off copies everything.
public struct ArmFilters: Equatable, Codable, Sendable {
    public var skipDeclined: Bool
    public var skipAllDay: Bool
    public var skipDontClone: Bool

    public init(skipDeclined: Bool = false, skipAllDay: Bool = false, skipDontClone: Bool = false) {
        self.skipDeclined = skipDeclined
        self.skipAllDay = skipAllDay
        self.skipDontClone = skipDontClone
    }

    public var isEmpty: Bool { self == ArmFilters() }
}
