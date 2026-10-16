import XCTest

@testable import CalopodMac

@MainActor
final class FirstRunProgressTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FirstRunProgressTests"))
        defaults.removePersistentDomain(forName: "FirstRunProgressTests")
        return defaults
    }

    func testStepsNeedAnAccountThenACalendar() throws {
        let progress = FirstRunProgress(defaults: try makeDefaults())
        XCTAssertFalse(progress.canContinue(connections: 0, selectedCalendars: 0))
        XCTAssertTrue(progress.canContinue(connections: 1, selectedCalendars: 0))
        progress.next()
        XCTAssertFalse(progress.canContinue(connections: 1, selectedCalendars: 0))
        XCTAssertTrue(progress.canContinue(connections: 1, selectedCalendars: 2))
        progress.next()
        XCTAssertTrue(progress.isLast)
        progress.next()
        XCTAssertEqual(progress.step, .destinations)
        progress.back()
        XCTAssertEqual(progress.step, .calendars)
    }

    func testSkippedSetupResumesWhereItStopped() throws {
        let defaults = try makeDefaults()
        let first = FirstRunProgress(defaults: defaults)
        XCTAssertTrue(first.shouldOpenAutomatically)
        first.begin()
        first.next()

        let resumed = FirstRunProgress(defaults: defaults)
        XCTAssertFalse(resumed.shouldOpenAutomatically)
        XCTAssertTrue(resumed.canResume)
        XCTAssertEqual(resumed.step, .calendars)
    }

    func testNothingIsApprovedUntilThePreviewIs() throws {
        let defaults = try makeDefaults()
        let progress = FirstRunProgress(defaults: defaults)
        progress.begin()
        progress.next()
        progress.next()
        XCTAssertFalse(progress.previewApproved)
        XCTAssertFalse(progress.isFinished)
        XCTAssertFalse(FirstRunProgress(defaults: defaults).isFinished)

        progress.approvePreview()
        XCTAssertTrue(progress.previewApproved)
        XCTAssertTrue(FirstRunProgress(defaults: defaults).isFinished)
        XCTAssertFalse(FirstRunProgress(defaults: defaults).canResume)
    }
}
