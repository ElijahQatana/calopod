/// Entries a provider marks as something other than a meeting.
public enum EventKind: String, Codable, Sendable {
    case workingLocation = "working-location"
    case birthday

    public init?(googleEventType: String?) {
        switch googleEventType {
        case "workingLocation": self = .workingLocation
        case "birthday": self = .birthday
        default: return nil
        }
    }

    public init?(microsoftShowAs: String?) {
        guard microsoftShowAs == "workingElsewhere" else { return nil }
        self = .workingLocation
    }
}
