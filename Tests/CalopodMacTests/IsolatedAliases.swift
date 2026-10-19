import Foundation

@testable import CalopodMac

extension CalendarAliases {
    /// Names and ignores that live in memory only, with preferences of their own.
    @MainActor
    static func isolated() -> CalendarAliases {
        CalendarAliases(defaults: UserDefaults(suiteName: "isolated-\(UUID().uuidString)")!, state: nil)
    }
}

extension CalendarColors {
    @MainActor
    static func isolated() -> CalendarColors {
        CalendarColors(defaults: UserDefaults(suiteName: "isolated-\(UUID().uuidString)")!, state: nil)
    }
}
