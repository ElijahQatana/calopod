import LocalAuthentication
import Security
import XCTest

@testable import CalopodStore

final class KeychainReadQueryTests: XCTestCase {
    private let reference = SecretReference(account: "example-account")

    func testQuietReadUsesAContextThatCannotPrompt() throws {
        let store = KeychainSecretStore(service: "example.test", allowsPrompt: false)
        let query = store.readQuery(for: reference)
        let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
    }

    func testNormalReadLeavesPromptingToTheSystem() {
        let store = KeychainSecretStore(service: "example.test")
        let query = store.readQuery(for: reference)
        XCTAssertNil(query[kSecUseAuthenticationContext as String])
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
        XCTAssertEqual(query[kSecAttrService as String] as? String, "example.test")
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
    }
}
