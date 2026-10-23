import CalopodSnapshot
import Foundation

struct Feed: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var isShared: Bool
    var level: SnapshotLevel
    var publishedAt: Date

    var label: String { level == .busy ? "\(name), busy time only" : name }
}

enum FeedChoice {
    /// The chosen feed if still there, else the newest of this phone's own, else the newest shared.
    static func pick(_ feeds: [Feed], preferred: String?) -> Feed? {
        if let preferred, let match = feeds.first(where: { $0.id == preferred }) { return match }
        let own = feeds.filter { !$0.isShared }
        return (own.isEmpty ? feeds : own).max { $0.publishedAt < $1.publishedAt }
    }

    static func ordered(_ feeds: [Feed]) -> [Feed] {
        feeds.sorted { ($0.isShared ? 1 : 0, $1.publishedAt) < ($1.isShared ? 1 : 0, $0.publishedAt) }
    }
}

final class FeedSelection: @unchecked Sendable {
    static let standard = FeedSelection(defaults: .standard)

    private let defaults: UserDefaults
    private let key = "selectedFeed"

    init(defaults: UserDefaults) { self.defaults = defaults }

    var preferred: String? {
        get { defaults.string(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}
