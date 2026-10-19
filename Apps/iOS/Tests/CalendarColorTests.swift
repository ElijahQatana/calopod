import CalopodDomain
import CalopodSnapshot
import SwiftUI
import Testing
import UIKit

@testable import Calopod

@MainActor
struct CalendarColorTests {
    private func hex(_ color: Color, _ style: UIUserInterfaceStyle) -> UInt32 {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: nil)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }

    private func entry(_ id: String?, _ index: Int) -> CalendarEntry? {
        CalendarEntry(id: "c", name: "Cal", colorIndex: index, color: id)
    }

    @Test func everyPaletteEntryHasTheMacsColors() {
        for (position, item) in CalendarPalette.entries.enumerated() {
            for calendar in [entry(item.id, 0), entry(nil, position)] {
                let color = Theme.calendarColor(calendar)
                #expect(hex(color, .light) == item.light, "\(item.id) light")
                #expect(hex(color, .dark) == item.dark, "\(item.id) dark")
            }
        }
    }

    @Test func anUnknownIdOrNoCalendarIsNeutral() {
        let neutral = CalendarPalette.neutral
        for color in [Theme.calendarColor(entry("mauve", 4)), Theme.calendarColor(nil)] {
            #expect(hex(color, .light) == neutral.light && hex(color, .dark) == neutral.dark)
        }
    }
}
