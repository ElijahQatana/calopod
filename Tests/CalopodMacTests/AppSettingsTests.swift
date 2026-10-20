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

    func testNothingIsSavedUntilASliderMovesAndResetClearsIt() {
        let suite = UserDefaults(suiteName: "calopod.tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: suite)
        for key in AppSettings.scaleKeys.values { XCTAssertNil(suite.object(forKey: key)) }
        settings.setPosition(.frame, 0.5)
        XCTAssertNotNil(suite.object(forKey: AppSettings.scaleKeys[.frame]!))
        settings.resetTransparency()
        for key in AppSettings.scaleKeys.values { XCTAssertNil(suite.object(forKey: key)) }
    }

    func testMenuBarItemIsOnUntilTurnedOffAndTheChoiceIsKept() {
        XCTAssertTrue(make().showsMenuBarItem)
        let suite = UserDefaults(suiteName: "calopod.tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: suite)
        settings.setShowsMenuBarItem(false)
        XCTAssertFalse(settings.showsMenuBarItem)
        XCTAssertFalse(AppSettings(defaults: suite).showsMenuBarItem)
        XCTAssertTrue(make([AppSettings.menuBarItemKey: "junk"]).showsMenuBarItem)
    }

    func testClosingTheWindowKeepsTheDockIconWhenTheMenuBarItemIsHidden() {
        XCTAssertEqual(DockPresence.closedPolicy(menuBarItemShown: true), .accessory)
        XCTAssertEqual(DockPresence.closedPolicy(menuBarItemShown: false), .regular)
    }

    func testDefaultsSitAtTheChosenLook() throws {
        let settings = make()
        XCTAssertEqual(settings.position(.frame), 1, accuracy: 1e-9)
        XCTAssertEqual(settings.position(.sidebar), 0.75, accuracy: 1e-9)
        // 65% on the former content range, which is 27.6% of the full one.
        XCTAssertEqual(settings.contentScale, 0.7604, accuracy: 0.0005)
        XCTAssertEqual(settings.position(.content), 0.2758, accuracy: 0.0005)
        XCTAssertEqual(settings.windowStyle, .frosted)
        // The tokens read the shared settings, so bring them to their defaults first.
        AppSettings.shared.resetTransparency()
        XCTAssertEqual(try alpha(Theme.frameTint, .aqua), 0, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.sidebarFill, .aqua), 0.325, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.sidebarSheen, .darkAqua), 0.35, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.contentFill, .aqua), 0.707, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.contentFill, .darkAqua), 0.692, accuracy: 0.005)
        XCTAssertEqual(try alpha(Theme.innerFill, .aqua), 0.738, accuracy: 0.005)
    }

    func testSliderPositionsRoundTrip() {
        let settings = make()
        for layer in [GlassLayer.frame, .sidebar, .content] {
            let scale = settings.scale(layer)
            settings.setPosition(layer, settings.position(layer))
            XCTAssertEqual(settings.scale(layer), scale, accuracy: 1e-9)
        }
    }

    func testEachSliderSpansItsWholeRangeWhateverTheOthersAre() {
        let settings = make()
        for (first, second) in [(0.0, 1.0), (1.0, 0.0)] {
            settings.setPosition(.frame, first)
            settings.setPosition(.sidebar, second)
            settings.setPosition(.content, first)
            for layer in [GlassLayer.frame, .sidebar, .content] {
                for position in [0.0, 0.5, 1.0] {
                    settings.setPosition(layer, position)
                    XCTAssertEqual(settings.position(layer), position, accuracy: 1e-9)
                }
            }
        }
        settings.setPosition(.content, 1)
        XCTAssertEqual(settings.contentScale, 0)
        settings.setPosition(.frame, 0)
        settings.setPosition(.sidebar, 1)
        XCTAssertEqual(settings.frameScale, 3)
        XCTAssertEqual(settings.sidebarScale, 0.3, accuracy: 1e-9)
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
        XCTAssertEqual(settings.contentScale, GlassBase.range(.content).lowerBound)
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
        XCTAssertEqual(WindowStyle.parse(nil), .frosted)
        XCTAssertEqual(WindowStyle.standard, .frosted)
        if !WindowStyle.glassAvailable { XCTAssertEqual(WindowStyle.parse("glass"), .frosted) }
    }
}
