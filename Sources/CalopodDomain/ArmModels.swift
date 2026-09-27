/// What an Arm is allowed to expose on its target calendar. `busy` mirrors
/// only free/busy state; `fullDetails` (used exclusively by the Main
/// calendar) carries title, location, and notes as well.
public enum ArmRuleMode: String, CaseIterable, Codable, Sendable {
    case busy
    case fullDetails = "full-details"
}
