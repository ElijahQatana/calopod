import CalopodRuntime
import XCTest

@testable import CalopodCommands

final class AppMessageTests: XCTestCase {
    func testAppMessagesDoNotSendAPersonToTheCommandLine() {
        let errors: [Error] = [
            LaunchAgentControlError.operationFailed("x"), LaunchAgentControlError.notInstalled,
            LaunchAgentControlError.unavailable, CalopodRuntimeError.missingGoogleClientID,
            CalopodRuntimeError.missingMicrosoftClientID, CalopodRuntimeError.missingEventKitHost,
            CalopodRuntimeError.eventKitHostFailed, CalopodRuntimeError.eventKitHostTimedOut,
            CalopodRuntimeError.eventKitHostUntrusted, CommandEnvironmentError.missingGoogleClientID,
        ]
        for error in errors {
            let text = appFailureMessage(error)
            for word in ["doctor", "CALOPOD_", "Info.plist", "from source", "user service", "EventKit"] {
                XCTAssertFalse(text.contains(word), "\(error): \(text)")
            }
        }
    }

    func testTheTerminalKeepsItsOwnWording() {
        XCTAssertTrue(commandFailure(LaunchAgentControlError.operationFailed("x")).message.contains("doctor"))
    }
}
