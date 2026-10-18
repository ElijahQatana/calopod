import AppKit
import SwiftUI
import XCTest

@testable import CalopodMac

@MainActor
final class ContrastTests: XCTestCase {
    private func rgb(_ color: Color, _ name: NSAppearance.Name) -> (Double, Double, Double) {
        var result = (0.0, 0.0, 0.0)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            result = (c.redComponent, c.greenComponent, c.blueComponent)
        }
        return result
    }

    private func luminance(_ c: (Double, Double, Double)) -> Double {
        func f(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.0) + 0.7152 * f(c.1) + 0.0722 * f(c.2)
    }

    private func ratio(_ a: Color, _ b: Color, _ name: NSAppearance.Name) -> Double {
        let (x, y) = (luminance(rgb(a, name)), luminance(rgb(b, name)))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testTextColorsReadOnBothSurfaces() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for (label, text) in [("good", Theme.goodText), ("caution", Theme.cautionText), ("bad", Theme.badText), ("accent", Theme.accent)] {
                for surface in [Theme.pane, Theme.group] {
                    XCTAssertGreaterThanOrEqual(ratio(text, surface, name), 4.5, "\(label) on \(name.rawValue)")
                }
            }
        }
    }
}
