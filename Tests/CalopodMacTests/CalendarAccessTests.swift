import CalopodCommands
import CalopodEventKit
import XCTest

@testable import CalopodMac

@MainActor
final class CalendarAccessTests: XCTestCase {
    func testStatusMapsToAState() {
        let cases: [(EventKitAccessStatus?, String?, CalendarAccessState)] = [
            (.fullAccess, nil, .granted),
            (.fullAccess, "permission", .granted),
            (.notDetermined, nil, .canAsk),
            (.denied, nil, .blocked),
            (.restricted, nil, .blocked),
            (.writeOnly, nil, .blocked),
            (.unknown, nil, .blocked),
            (nil, nil, .unchecked),
            (nil, "temporary", .unchecked),
            (nil, "permission", .blocked),
        ]
        for (status, failure, expected) in cases {
            XCTAssertEqual(.resolve(status: status, lastSyncFailure: failure), expected, "\(String(describing: status)) \(String(describing: failure))")
        }
    }

    func testOnlyMissingAccessIsFlagged() {
        XCTAssertTrue(CalendarAccessState.canAsk.isMissing)
        XCTAssertTrue(CalendarAccessState.blocked.isMissing)
        XCTAssertFalse(CalendarAccessState.granted.isMissing)
        XCTAssertFalse(CalendarAccessState.unchecked.isMissing)
    }

    func testAllowAsksThroughTheHostAndClearsOnceGranted() async {
        let host = FakeHost(status: .notDetermined, afterRequest: .fullAccess)
        let model = host.model()
        await model.check()
        XCTAssertEqual(model.state(lastSyncFailure: nil), .canAsk)
        await model.allow()
        XCTAssertEqual(host.requests, 1)
        XCTAssertEqual(model.state(lastSyncFailure: nil), .granted)
    }

    func testDeniedStaysBlockedAndOpensTheCalendarsPrivacyPage() async {
        let host = FakeHost(status: .denied, afterRequest: .denied)
        let model = host.model()
        await model.check()
        XCTAssertEqual(model.state(lastSyncFailure: nil), .blocked)
        model.openPrivacySettings()
        XCTAssertEqual(
            host.opened.map(\.absoluteString),
            ["x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"])
    }

    func testAccessGrantedInSettingsClearsOnTheNextCheck() async {
        let host = FakeHost(status: .denied, afterRequest: .denied)
        let model = host.model()
        await model.check()
        host.setStatus(.fullAccess)
        await model.check()
        XCTAssertEqual(model.state(lastSyncFailure: "permission"), .granted)
    }

    func testAllowShowsABusyStateThenTheResult() async {
        let gate = DispatchSemaphore(value: 0)
        let model = CalendarAccessModel(
            readStatus: { .notDetermined },
            requestAccess: { gate.wait(); return CalendarAccessAnswer(status: .fullAccess, outcome: .granted) },
            readHelper: { nil },
            open: { _ in })
        let task = Task { await model.allow() }
        while !model.asking { await Task.yield() }
        XCTAssertNil(model.result)
        gate.signal()
        await task.value
        XCTAssertFalse(model.asking)
        XCTAssertEqual(model.result?.message, "Calendar access is allowed.")
    }

    func testEveryOutcomeHasAMessageAndOnlyUndecidedOrDeniedOfferWaysForward() {
        let cases: [(CalendarAccessOutcome, Bool)] = [
            (.granted, false), (.denied, true), (.undecided, true), (.couldNotStart, false),
        ]
        for (outcome, ways) in cases {
            let result = CalendarAccessResult.after(outcome)
            XCTAssertFalse(result.message.isEmpty, "\(outcome)")
            XCTAssertEqual(result.offersWaysForward, ways, "\(outcome)")
        }
        XCTAssertTrue(CalendarAccessResult.after(.undecided).message.contains("macOS did not show the prompt"))
        XCTAssertFalse(CalendarAccessResult.resetFailed.message.isEmpty)
    }

    func testTheCardNamesTheHelperWithTheCommandLineWords() async {
        let model = FakeHost(status: .denied, afterRequest: .denied).model()
        XCTAssertNil(model.guidance())
        await model.check()
        let guidance = model.guidance(home: "/Volumes/example-home")
        XCTAssertEqual(guidance?.helperPath, "/Applications/Calopod.app/Contents/MacOS/eventkit-host/Calopod EventKit Host.app")
        XCTAssertTrue(guidance?.message.contains("macOS lists it as \"Calopod\"") ?? false)
    }

    func testAStillUndecidedAnswerSaysSoAndOffersTheWaysForward() async {
        let host = FakeHost(status: .notDetermined, afterRequest: .notDetermined)
        let model = host.model()
        await model.allow()
        XCTAssertEqual(model.state(lastSyncFailure: nil), .canAsk)
        XCTAssertEqual(model.result, .after(.undecided))
        XCTAssertEqual(model.result?.offersWaysForward, true)
    }

    func testAnUnreachableHelperDuringAllowStillGivesAMessage() async {
        let host = FakeHost(status: .notDetermined, afterRequest: .fullAccess)
        let model = CalendarAccessModel(
            readStatus: { .notDetermined }, requestAccess: { throw FakeHost.Unreachable() },
            readHelper: { nil }, open: { _ in })
        await model.allow()
        XCTAssertFalse(model.result?.message.isEmpty ?? true)
        XCTAssertEqual(model.result?.offersWaysForward, false)
        _ = host
    }

    func testResetAsksForConfirmationThenRunsTheResetAndAsksAgain() async {
        let host = FakeHost(status: .denied, afterRequest: .fullAccess)
        let model = host.model()
        await model.check()
        model.askToReset()
        XCTAssertTrue(model.confirmingReset)
        XCTAssertEqual(host.resets, 0)
        model.cancelReset()
        XCTAssertFalse(model.confirmingReset)
        XCTAssertEqual(host.resets, 0)
        model.askToReset()
        await model.confirmReset()
        XCTAssertEqual(host.resets, 1)
        XCTAssertEqual(host.requests, 1)
        XCTAssertFalse(model.confirmingReset)
        XCTAssertEqual(model.state(lastSyncFailure: nil), .granted)
    }

    func testAFailedResetSaysSoWithTheCommandAndDoesNotAsk() async {
        let host = FakeHost(status: .denied, afterRequest: .fullAccess)
        host.resetFails = true
        let model = host.model()
        await model.confirmReset()
        XCTAssertEqual(host.requests, 0)
        XCTAssertTrue(model.result?.message.contains(Permissions.calendarResetCommand) == true)
    }

    func testAnUnreachableHostKeepsTheLastAnswer() async {
        let host = FakeHost(status: .denied, afterRequest: .denied)
        let model = host.model()
        await model.check()
        host.fail = true
        await model.check()
        XCTAssertEqual(model.state(lastSyncFailure: nil), .blocked)
    }
}

private final class FakeHost: @unchecked Sendable {
    struct Unreachable: Error {}
    private let lock = NSLock()
    private var status: EventKitAccessStatus
    private let afterRequest: EventKitAccessStatus
    private var _requests = 0
    private var _fail = false
    private var _resets = 0
    private var _resetFails = false
    private(set) var opened: [URL] = []

    init(status: EventKitAccessStatus, afterRequest: EventKitAccessStatus) {
        self.status = status
        self.afterRequest = afterRequest
    }

    var requests: Int { lock.withLock { _requests } }
    var resets: Int { lock.withLock { _resets } }
    var resetFails: Bool {
        get { lock.withLock { _resetFails } }
        set { lock.withLock { _resetFails = newValue } }
    }
    var fail: Bool {
        get { lock.withLock { _fail } }
        set { lock.withLock { _fail = newValue } }
    }

    func setStatus(_ new: EventKitAccessStatus) { lock.withLock { status = new } }

    @MainActor func model() -> CalendarAccessModel {
        CalendarAccessModel(
            readStatus: { [self] in
                try lock.withLock {
                    if _fail { throw Unreachable() }
                    return status
                }
            },
            requestAccess: { [self] in
                lock.withLock {
                    _requests += 1
                    if status == .notDetermined { status = afterRequest }
                    return CalendarAccessAnswer(status: status, outcome: CalendarAccessOutcome(statusAfterRequest: status))
                }
            },
            readHelper: { "/Applications/Calopod.app/Contents/MacOS/eventkit-host/Calopod EventKit Host.app" },
            resetDecision: { [self] in
                try lock.withLock {
                    if _resetFails { throw Unreachable() }
                    _resets += 1
                    status = .notDetermined
                }
            },
            open: { [self] in opened.append($0) })
    }
}

final class DevHelperChoiceTests: XCTestCase {
    private func layout() throws -> (executable: URL, installed: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("calopod-dev-host-\(UUID().uuidString)", isDirectory: true)
        let macOS = root.appendingPathComponent("Calopod.app/Contents/MacOS", isDirectory: true)
        let installed = root.appendingPathComponent("Service/eventkit-host/Calopod EventKit Host.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOS.appendingPathComponent("eventkit-host/Calopod EventKit Host.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        return (macOS.appendingPathComponent("CalopodMac"), installed, root)
    }

    func testATrustedBundledHelperBeatsTheSourceInstall() throws {
        let found = try layout()
        defer { try? FileManager.default.removeItem(at: found.root) }
        XCTAssertNil(AppConfiguration.devHost(
            environment: [:], executableURL: found.executable, installed: found.installed, verify: { _ in }))
    }

    func testAnUntrustedBundledHelperFallsBackToTheSourceInstall() throws {
        let found = try layout()
        defer { try? FileManager.default.removeItem(at: found.root) }
        let host = AppConfiguration.devHost(
            environment: [:], executableURL: found.executable, installed: found.installed,
            verify: { _ in throw EventKitHostSignatureError.untrusted })
        XCTAssertEqual(host, found.installed)
    }

    func testASetPathIsLeftAlone() throws {
        let found = try layout()
        defer { try? FileManager.default.removeItem(at: found.root) }
        XCTAssertNil(AppConfiguration.devHost(
            environment: ["CALOPOD_EVENTKIT_HOST_APP": "/example/host.app"], executableURL: found.executable,
            installed: found.installed, verify: { _ in throw EventKitHostSignatureError.untrusted }))
    }
}
