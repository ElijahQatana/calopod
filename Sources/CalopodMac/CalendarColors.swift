import CalopodCommands
import CalopodStore
import Foundation
import Observation
import SwiftUI

/// One of the twelve colors a calendar can use. Dark values are lifted to hold up on dark surfaces.
struct CalendarColor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let light: UInt32
    let dark: UInt32

    /// Palette colors are built once; a dynamic color costs more than it looks per event block.
    var color: Color { Self.built[id] ?? make() }

    private static let built = Dictionary(uniqueKeysWithValues: palette.map { ($0.id, $0.make()) })

    private func make() -> Color { Color(light: Self.color(light), dark: Self.color(dark)) }

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }

    /// Distance between two palette colors, weighted toward what the eye separates most.
    func distance(to other: CalendarColor) -> Double {
        func parts(_ hex: UInt32) -> (Double, Double, Double) {
            (Double((hex >> 16) & 0xff), Double((hex >> 8) & 0xff), Double(hex & 0xff))
        }
        let a = parts(light), b = parts(other.light)
        let redMean = (a.0 + b.0) / 2
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        return ((2 + redMean / 256) * dr * dr + 4 * dg * dg + (2 + (255 - redMean) / 256) * db * db).squareRoot()
    }
}

extension CalendarColor {
    /// The palette color closest to a provider's `#rrggbb`, so a match still stays within the twelve.
    static func nearest(toHex hex: String) -> CalendarColor? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        let probe = CalendarColor(id: "", name: "", light: value, dark: value)
        return palette.min { $0.distance(to: probe) < $1.distance(to: probe) }
    }

    static let palette: [CalendarColor] = CalendarPalette.entries.map {
        CalendarColor(id: $0.id, name: $0.name, light: $0.light, dark: $0.dark)
    }

    static func named(_ id: String) -> CalendarColor? { palette.first { $0.id == id } }

    /// The color to give a new calendar, given the palette ids already in use (repeats count).
    /// Prefers the least used colors, then the one farthest from every other color in use.
    static func suggestion(avoiding used: [String]) -> CalendarColor {
        let counts = used.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let inUse = palette.filter { counts[$0.id] != nil }
        let fewest = palette.map { counts[$0.id] ?? 0 }.min() ?? 0
        let candidates = palette.filter { (counts[$0.id] ?? 0) == fewest }
        func gap(_ color: CalendarColor) -> Double {
            inUse.filter { $0.id != color.id }.map { color.distance(to: $0) }.min() ?? .infinity
        }
        // max(by:) keeps the first of equal scores, so palette order breaks ties.
        return candidates.max { gap($0) < gap($1) } ?? palette[0]
    }
}

/// What the provider says about a calendar's color, as far as it is known.
struct CalendarColorSource: Equatable, Sendable {
    let id: String
    /// `#rrggbb` as the provider or Calendar app reports it.
    let providerColor: String?
    /// "google", "microsoft" or "eventkit".
    let provider: String

    init(id: String, providerColor: String? = nil, provider: String = "") {
        self.id = id
        self.providerColor = providerColor
        self.provider = provider
    }

    /// The palette color that stands in for the provider's color.
    var matched: CalendarColor? { providerColor.flatMap(CalendarColor.nearest(toHex:)) }

    var providerName: String {
        switch provider {
        case "google": "Google"
        case "microsoft": "Microsoft"
        default: "Calendar app"
        }
    }
}

/// Calendar colors chosen on this Mac. They are never written to a calendar at the provider.
@MainActor
@Observable
final class CalendarColors {
    static let shared = CalendarColors(defaults: AppDefaults.forSingleton, state: try? LocalState.repository())

    private(set) var choices: [String: String]
    private(set) var sources: [String: CalendarColorSource] = [:]
    @ObservationIgnored private let state: LocalStateRepository?

    /// Colors live in the local state database. Without one they last until the app quits. The
    /// defaults are only read once, to move colors an earlier version kept there.
    init(defaults: UserDefaults, state: LocalStateRepository?) {
        self.state = state
        if let state { CalendarPreferenceMigration.run(defaults: defaults, state: state) }
        choices = ((try? state?.calendarPreferences()) ?? [:]).compactMapValues(\.color)
    }

    /// The chosen color for a calendar, or a neutral one until it has been given a color.
    func color(for calendarID: String) -> CalendarColor {
        choices[calendarID].flatMap(CalendarColor.named) ?? CalendarColor.named("gray")!
    }

    func set(_ color: CalendarColor, for calendarID: String) {
        choices[calendarID] = color.id
        save([calendarID])
    }

    /// The color to offer for matching the provider, if it reported one.
    func providerMatch(for calendarID: String) -> (name: String, color: CalendarColor)? {
        guard let source = sources[calendarID], let color = source.matched else { return nil }
        return (source.providerName, color)
    }

    func matchProvider(for calendarID: String) {
        if let match = providerMatch(for: calendarID) { set(match.color, for: calendarID) }
    }

    /// Gives every calendar without a color one, in the order listed. Mac calendars start with their
    /// Calendar app color; the rest get a suggestion. A color someone chose is never replaced.
    /// Ignored calendars do not count when picking a suggestion, so they do not use up a color.
    func assignMissing(to calendars: [CalendarColorSource], ignoring ignored: Set<String> = []) {
        var changed: [String] = []
        for source in calendars {
            sources[source.id] = source
            guard choices[source.id].flatMap(CalendarColor.named) == nil else { continue }
            let isMac = source.provider == "eventkit"
            choices[source.id] = (isMac ? source.matched : nil)?.id
                ?? CalendarColor.suggestion(avoiding: choices.filter { !ignored.contains($0.key) }.map(\.value)).id
            changed.append(source.id)
        }
        save(changed)
    }

    private func save(_ ids: [String]) {
        for id in ids { try? state?.setCalendarColor(choices[id], calendarID: id) }
    }
}
