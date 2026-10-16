import Foundation
import Observation
import SwiftUI

/// One of the twelve colors a calendar can use. Dark values are lifted to hold up on dark surfaces.
struct CalendarColor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let light: UInt32
    let dark: UInt32

    var color: Color { Color(light: Self.color(light), dark: Self.color(dark)) }

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
    static let palette: [CalendarColor] = [
        CalendarColor(id: "blue", name: "Blue", light: 0x3a5fcd, dark: 0x7b9af0),
        CalendarColor(id: "orange", name: "Orange", light: 0xd9731a, dark: 0xf2a04a),
        CalendarColor(id: "green", name: "Green", light: 0x2f9e5f, dark: 0x5cc88b),
        CalendarColor(id: "purple", name: "Purple", light: 0x9a4fc0, dark: 0xc58be8),
        CalendarColor(id: "red", name: "Red", light: 0xc8453b, dark: 0xef7b6f),
        CalendarColor(id: "teal", name: "Teal", light: 0x12908e, dark: 0x4cc3c0),
        CalendarColor(id: "pink", name: "Pink", light: 0xcc4a8f, dark: 0xef82bb),
        CalendarColor(id: "amber", name: "Amber", light: 0xb8860b, dark: 0xe5b83a),
        CalendarColor(id: "sky", name: "Sky", light: 0x1f8ac4, dark: 0x5db4ec),
        CalendarColor(id: "lime", name: "Lime", light: 0x6f9a1f, dark: 0xa3c94f),
        CalendarColor(id: "indigo", name: "Indigo", light: 0x5b4bc4, dark: 0x9a8cf0),
        CalendarColor(id: "gray", name: "Gray", light: 0x6b7280, dark: 0xa1a8b3),
    ]

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

/// Calendar colors chosen on this Mac. They are never written to a calendar at the provider.
@MainActor
@Observable
final class CalendarColors {
    static let shared = CalendarColors()

    private static let defaultsKey = "calendarColors"

    private(set) var choices: [String: String]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choices = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    /// The chosen color for a calendar, or a neutral one until it has been given a color.
    func color(for calendarID: String) -> CalendarColor {
        choices[calendarID].flatMap(CalendarColor.named) ?? CalendarColor.named("gray")!
    }

    func set(_ color: CalendarColor, for calendarID: String) {
        choices[calendarID] = color.id
        save()
    }

    /// Gives every calendar without a color a suggested one, in the order listed.
    func assignMissing(to calendarIDs: [String]) {
        var changed = false
        for id in calendarIDs where choices[id].flatMap(CalendarColor.named) == nil {
            choices[id] = CalendarColor.suggestion(avoiding: Array(choices.values)).id
            changed = true
        }
        if changed { save() }
    }

    private func save() { defaults.set(choices, forKey: Self.defaultsKey) }
}
