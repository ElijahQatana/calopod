public enum ProviderKind: String, CaseIterable, Codable, Sendable {
    case eventKit = "eventkit"
    case google
    case ics
    case microsoft
}
