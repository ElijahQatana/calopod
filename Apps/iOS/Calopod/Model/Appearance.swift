import Observation
import SwiftUI

/// Light, dark or whatever iOS is set to. It is a choice for this phone and applies to the whole app.
@Observable
final class Appearance {
    enum Choice: String, CaseIterable {
        case system, light, dark

        var title: String { rawValue.capitalized }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    var choice: Choice {
        didSet { defaults.set(choice.rawValue, forKey: Self.key) }
    }

    private let defaults: UserDefaults
    static let key = "appearance"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = defaults.string(forKey: Self.key).flatMap(Choice.init) ?? .system
    }
}
