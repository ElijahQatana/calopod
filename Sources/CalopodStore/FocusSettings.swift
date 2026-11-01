import Foundation
import GRDB

public enum FocusSettingsError: Error, Equatable, LocalizedError {
    case minutesOutOfRange

    public var errorDescription: String? { "The focus length must be between 15 minutes and 24 hours." }
}

/// The shortest free stretch that counts as focus time, kept in the local state so the Mac app and
/// the command line share one copy.
public struct FocusSettings: Equatable, Sendable {
    public static let minutes = 15...1440

    public let minutes: Int

    public init(minutes: Int = 120) throws {
        guard Self.minutes.contains(minutes) else { throw FocusSettingsError.minutesOutOfRange }
        self.minutes = minutes
    }

    public static let standard = try! FocusSettings()

    public var seconds: TimeInterval { TimeInterval(minutes * 60) }
}

extension LocalStateRepository {
    /// The saved length, or two hours when nothing was saved or the saved row cannot be used.
    public func focusSettings() throws -> FocusSettings {
        try database.read { db in
            guard let minutes: Int = try Row.fetchOne(db, sql: "SELECT minutes FROM focus_settings WHERE id = 1")?["minutes"]
            else { return .standard }
            return (try? FocusSettings(minutes: minutes)) ?? .standard
        }
    }

    public func saveFocusSettings(_ settings: FocusSettings) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO focus_settings (id, minutes) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET minutes = excluded.minutes
                """, arguments: [settings.minutes])
        }
    }
}
