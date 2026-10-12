/// What an Arm may put on its target. `busy` is timing only; `fullDetails` (Main calendar) adds
/// title, location and notes.
public enum ArmRuleMode: String, CaseIterable, Codable, Sendable {
    case busy
    case fullDetails = "full-details"
}
