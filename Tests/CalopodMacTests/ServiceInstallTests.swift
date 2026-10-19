import XCTest

@testable import CalopodMac

final class ServiceInstallTests: XCTestCase {
    private struct Refused: Error {}

    private final class Registrar: BundledServiceRegistering, @unchecked Sendable {
        var states: [ServiceRegistration.State]
        var registerFails = false
        private(set) var registered = 0
        init(_ states: [ServiceRegistration.State]) { self.states = states }
        func state() -> ServiceRegistration.State { states.count > 1 ? states.removeFirst() : states[0] }
        func register() throws {
            registered += 1
            if registerFails { throw Refused() }
        }
    }

    /// Runs the install and returns what happened to the old service, in order.
    private func run(
        legacy: Bool, _ registrar: Registrar
    ) -> (calls: [Bool], error: Error?) {
        var calls: [Bool] = []
        do {
            try ServiceModel.install(legacyActive: legacy, registrar: registrar, setLegacyEnabled: { calls.append($0) })
            return (calls, nil)
        } catch {
            return (calls, error)
        }
    }

    func testTheOldServiceStopsBeforeTheNewOneIsRegistered() {
        let registrar = Registrar([.notRegistered, .enabled])
        let result = run(legacy: true, registrar)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.calls, [false])
        XCTAssertEqual(registrar.registered, 1)
    }

    func testAFailedRegistrationTurnsTheOldServiceBackOn() {
        let registrar = Registrar([.notRegistered])
        registrar.registerFails = true
        let result = run(legacy: true, registrar)
        XCTAssertTrue(result.error is Refused)
        XCTAssertEqual(result.calls, [false, true])
    }

    func testWaitingForApprovalTurnsTheOldServiceBackOn() {
        let registrar = Registrar([.notRegistered, .requiresApproval])
        let result = run(legacy: true, registrar)
        XCTAssertEqual(result.error as? ServiceModel.InstallError, .needsApproval)
        XCTAssertEqual(result.calls, [false, true])
    }

    func testNothingIsToggledWhenNoOldServiceRuns() {
        let registrar = Registrar([.notRegistered, .requiresApproval])
        let result = run(legacy: false, registrar)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.calls, [])
    }

    func testAnAlreadyApprovedServiceIsNotRegisteredTwice() {
        let registrar = Registrar([.enabled])
        registrar.registerFails = true
        let result = run(legacy: true, registrar)
        XCTAssertNil(result.error)
        XCTAssertEqual(registrar.registered, 0)
        XCTAssertEqual(result.calls, [false])
    }
}

final class ServiceWindowTextTests: XCTestCase {
    func testWindowTextNamesBothSides() {
        XCTAssertEqual(
            ServiceModel.windowText(lookbackDays: 7, horizonDays: 15), "Looks back 7 days, plans 15 days ahead")
        XCTAssertEqual(
            ServiceModel.windowText(lookbackDays: 1, horizonDays: 1), "Looks back 1 day, plans 1 day ahead")
        XCTAssertNil(ServiceModel.windowText(lookbackDays: nil, horizonDays: 15))
    }
}
