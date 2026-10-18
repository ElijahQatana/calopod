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
    private(set) var opened: [URL] = []

    init(status: EventKitAccessStatus, afterRequest: EventKitAccessStatus) {
        self.status = status
        self.afterRequest = afterRequest
    }

    var requests: Int { lock.withLock { _requests } }
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
                    return status
                }
            },
            open: { [self] in opened.append($0) })
    }
}
