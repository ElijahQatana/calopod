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
