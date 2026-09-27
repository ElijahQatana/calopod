/// The calendar backends Calopod can connect to. `eventKit` is the local
/// Mac calendar store; `google` and `microsoft` are hosted providers reached
/// over OAuth; `ics` is a read-only subscription feed.
public enum ProviderKind: String, CaseIterable, Codable, Sendable {
    case eventKit = "eventkit"
    case google
    case ics
    case microsoft
}
