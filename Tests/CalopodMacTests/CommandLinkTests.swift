import XCTest

@testable import CalopodMac

final class CommandLinkTests: XCTestCase {
    private var root: URL!
    private var link: CommandLink!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("command-link-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Applications/Calopod.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try script(at: macOS.appendingPathComponent("calopod"))
        link = CommandLink(home: root.appendingPathComponent("home"), bundle: bundle)
    }

    override func tearDownWithError() throws { try? fileManager.removeItem(at: root) }

    private func script(at url: URL) throws {
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeBin() throws {
        try fileManager.createDirectory(at: link.binDirectory, withIntermediateDirectories: true)
    }

    private func pointLink(at path: String) throws {
        try makeBin()
        try fileManager.createSymbolicLink(atPath: link.linkURL.path, withDestinationPath: path)
    }

    func testNothingThereIsNotInstalled() {
        XCTAssertEqual(link.state(), .notInstalled)
        XCTAssertTrue(link.commandIsBundled)
    }

    func testInstallLinksIntoTheAppAndCreatesTheFolder() throws {
        try link.install()
        XCTAssertEqual(link.state(), .installed)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: link.linkURL.path), link.commandURL.path)
    }

    func testRemoveDeletesAnAppLink() throws {
        try link.install()
        try link.remove()
        XCTAssertEqual(link.state(), .notInstalled)
    }

    func testAWorkingLinkElsewhereNeedsConfirmationToReplace() throws {
        let other = root.appendingPathComponent("source/calopod")
        try fileManager.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script(at: other)
        try pointLink(at: other.path)
        XCTAssertEqual(link.state(), .elsewhere(target: other.standardizedFileURL.path))
        XCTAssertThrowsError(try link.install()) { XCTAssertEqual($0 as? CommandLink.Failure, .needsReplaceConfirmation) }
        XCTAssertEqual(link.state(), .elsewhere(target: other.standardizedFileURL.path))
        try link.install(replacingOther: true)
        XCTAssertEqual(link.state(), .installed)
        XCTAssertTrue(fileManager.fileExists(atPath: other.path))
    }

    func testAMissingTargetIsBrokenAndInstallRepairsIt() throws {
        let gone = root.appendingPathComponent("gone/calopod").path
        try pointLink(at: gone)
        XCTAssertEqual(link.state(), .broken(target: URL(fileURLWithPath: gone).standardizedFileURL.path))
        try link.install()
        XCTAssertEqual(link.state(), .installed)
    }

    func testALinkIntoAnAppWhoseCommandIsGoneIsStillOurs() throws {
        try link.install()
        try fileManager.removeItem(at: link.commandURL)
        XCTAssertEqual(link.state(), .installed)
        try link.remove()
        XCTAssertEqual(link.state(), .notInstalled)
    }

    func testARelativeLinkIntoTheAppCountsAsInstalled() throws {
        let relative = "../../../Applications/Calopod.app/Contents/MacOS/calopod"
        try pointLink(at: relative)
        XCTAssertEqual(link.state(), .installed)
    }

    func testARegularFileIsLeftAloneByInstallAndRemove() throws {
        try makeBin()
        try "keep".write(to: link.linkURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(link.state(), .occupied)
        XCTAssertThrowsError(try link.install()) { XCTAssertEqual($0 as? CommandLink.Failure, .occupied) }
        XCTAssertThrowsError(try link.remove()) { XCTAssertEqual($0 as? CommandLink.Failure, .notInThisApp) }
        XCTAssertEqual(try String(contentsOf: link.linkURL, encoding: .utf8), "keep")
    }

    func testRemoveKeepsALinkToSomewhereElse() throws {
        let other = root.appendingPathComponent("other/calopod")
        try fileManager.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script(at: other)
        try pointLink(at: other.path)
        XCTAssertThrowsError(try link.remove())
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: link.linkURL.path), other.path)
    }

    func testAnAppWithSimilarNameIsNotThisApp() throws {
        try pointLink(at: link.bundle.path + "Other/Contents/MacOS/calopod")
        XCTAssertThrowsError(try link.remove())
    }

    func testPathCheckLooksAtPathAndProfiles() throws {
        XCTAssertFalse(link.binIsOnPath(environment: ["PATH": "/usr/bin:/bin"]))
        XCTAssertTrue(link.binIsOnPath(environment: ["PATH": "/usr/bin:\(link.binDirectory.path)"]))
        try "export PATH=\"$HOME/.local/bin:$PATH\"\n".write(
            to: link.home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        XCTAssertTrue(link.binIsOnPath(environment: [:]))
    }
}
