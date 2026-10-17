import AppKit
import SwiftUI
import XCTest

@testable import CalopodMac

@MainActor
final class AppSettingsTests: XCTestCase {
    private func make(_ values: [String: Any] = [:]) -> AppSettings {
        let suite = UserDefaults(suiteName: "calopod.tests.\(UUID().uuidString)")!
        for (key, value) in values { suite.set(value, forKey: key) }
        return AppSettings(defaults: suite)
    }

    private func alpha(_ color: Color, _ name: NSAppearance.Name) throws -> Double {
        var result = 0.0
        try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
            result = Double(NSColor(color).usingColorSpace(.sRGB)!.alphaComponent)
        }
        return result
    }

    func testDefaultsSitAtTheChosenSliderPositions() throws {
        let settings = make()
        XCTAssertEqual(settings.position(.frame), 0.85, accuracy: 1e-9)
        XCTAssertEqual(settings.position(.sidebar), 0.15, accuracy: 1e-9)
        XCTAssertEqual(settings.position(.content), 0.05, accuracy: 1e-9)
        // The tokens read the shared settings, so bring them to their defaults first.
        AppSettings.shared.resetTransparency()
        XCTAssertEqual(try alpha(Theme.frameTint, .aqua), 0.045, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.frameTint, .darkAqua), 0.036, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.sidebarFill, .aqua), 0.73, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.sidebarSheen, .aqua), 0.815, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.sidebarSheen, .darkAqua), 0.787, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.contentFill, .aqua), 0.956, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.contentFill, .darkAqua), 0.935, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.innerFill, .aqua), 0.997, accuracy: 0.005)
    }

    func testSliderPositionsRoundTrip() {
        let settings = make()
        for layer in [GlassLayer.frame, .sidebar, .content] {
            let scale = settings.scale(layer)
            settings.setPosition(layer, settings.position(layer))
            XCTAssertEqual(settings.scale(layer), scale, accuracy: 1e-9)
        }
    }

    func testOrderIsKeptWithAGap() {
        let settings = make()
        settings.setPosition(.frame, 0) // firmest frame
        settings.setPosition(.sidebar, 1) // most see-through sidebar
        // The frame cannot be firmer than the sidebar is.
        XCTAssertLessThan(
            GlassBase.frame.light * settings.frameScale + GlassBase.gap - 1e-9,
            GlassBase.sidebarFill.light * settings.sidebarScale + 1e-9)
        settings.setPosition(.content, 1)
        settings.setPosition(.sidebar, 0) // firmest sidebar
        XCTAssertLessThanOrEqual(
            GlassBase.sidebarSheen.dark * settings.sidebarScale + GlassBase.gap,
            GlassBase.content.dark * settings.contentScale + 1e-9)
    }

    func testContentFillHasAFloor() {
        let settings = make()
        settings.setPosition(.content, 1)
        XCTAssertGreaterThanOrEqual(GlassBase.content.dark * settings.contentScale, GlassBase.contentFloor - 1e-9)
        XCTAssertGreaterThanOrEqual(GlassBase.content.light * settings.contentScale, GlassBase.contentFloor)
    }

    func testResetGoesBackToDefaults() {
        let settings = make()
        settings.setPosition(.frame, 1)
        settings.setPosition(.sidebar, 0.1)
        settings.setPosition(.content, 1)
        settings.resetTransparency()
        for layer in [GlassLayer.frame, .sidebar, .content] {
            XCTAssertEqual(settings.scale(layer), GlassBase.defaultScale(layer), accuracy: 1e-9)
        }
    }

    func testGarbageStoredValuesAreClampedOrIgnored() {
        let settings = make([
            AppSettings.scaleKeys[.frame]!: 99, AppSettings.scaleKeys[.sidebar]!: "x", AppSettings.scaleKeys[.content]!: -4,
            AppSettings.appearanceKey: "purple", AppSettings.windowStyleKey: "nonsense",
        ])
        XCTAssertLessThanOrEqual(settings.frameScale, GlassBase.range(.frame).upperBound)
        XCTAssertEqual(settings.sidebarScale, GlassBase.defaultScale(.sidebar))
        XCTAssertGreaterThanOrEqual(settings.contentScale, GlassBase.range(.content).lowerBound)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.windowStyle, WindowStyle.standard)
    }

    func testChoicesPersist() {
        let suite = UserDefaults(suiteName: "calopod.tests.\(UUID().uuidString)")!
        let first = AppSettings(defaults: suite)
        first.setPosition(.sidebar, 0.8)
        first.setWindowStyle(.solid)
        let again = AppSettings(defaults: suite)
        XCTAssertEqual(again.sidebarScale, first.sidebarScale, accuracy: 1e-9)
        XCTAssertEqual(again.windowStyle, .solid)
    }

    func testAppearanceParsing() {
        XCTAssertEqual(AppearanceChoice.parse("dark"), .dark)
        XCTAssertEqual(AppearanceChoice.parse("light"), .light)
        XCTAssertEqual(AppearanceChoice.parse(nil), .system)
        XCTAssertNil(AppearanceChoice.system.nsAppearance)
        XCTAssertEqual(AppearanceChoice.dark.nsAppearance?.name, .darkAqua)
    }

    func testWindowStyleFallsBackWhereGlassIsMissing() {
        XCTAssertEqual(WindowStyle.parse("solid"), .solid)
        XCTAssertEqual(WindowStyle.parse("frosted"), .frosted)
        XCTAssertEqual(WindowStyle.parse(nil), WindowStyle.standard)
        if !WindowStyle.glassAvailable { XCTAssertEqual(WindowStyle.parse("glass"), .frosted) }
    }
}
