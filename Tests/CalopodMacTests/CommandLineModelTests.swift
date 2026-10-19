import XCTest

@testable import CalopodMac

@MainActor
final class CommandLineModelTests: XCTestCase {
    private var root: URL!
    private var link: CommandLink!
    private let fileManager = FileManager.default

    override func setUp() async throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("command-model-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Applications/Calopod.app", isDirectory: true)
        try fileManager.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        link = CommandLink(home: root.appendingPathComponent("home"), bundle: bundle)
        try fileManager.createDirectory(at: link.binDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? fileManager.removeItem(at: root) }

    private func pointElsewhere() throws -> String {
        let other = root.appendingPathComponent("source/calopod")
        try fileManager.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: other, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(atPath: link.linkURL.path, withDestinationPath: other.path)
        return other.path
    }

    func testReplacingAnotherLinkAsksFirstThenReplaces() throws {
        _ = try pointElsewhere()
        let model = CommandLineModel(link: link)
        model.install()
        XCTAssertTrue(model.confirmingReplace)
        XCTAssertNil(model.notice)
        model.install()
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.confirmingReplace)
        XCTAssertEqual(model.state, .installed)
    }

    func testCancelLeavesTheOtherLinkAlone() throws {
        let other = try pointElsewhere()
        let model = CommandLineModel(link: link)
        model.install()
        model.cancelReplace()
        XCTAssertFalse(model.confirmingReplace)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: link.linkURL.path), other)
        model.install()
        XCTAssertTrue(model.confirmingReplace, "asks again after a cancel")
    }

    func testNoticesNeverShowTheTypeName() throws {
        try "keep".write(to: link.linkURL, atomically: true, encoding: .utf8)
        let model = CommandLineModel(link: link)
        model.install()
        XCTAssertNotNil(model.notice)
        model.remove()
        XCTAssertNotNil(model.notice)
        XCTAssertFalse(model.notice?.contains("CommandLink") ?? false)
        XCTAssertFalse(model.notice?.contains("Failure") ?? false)
    }

    func testRemoveAndRepairWorkWithoutConfirmation() throws {
        try fileManager.createSymbolicLink(atPath: link.linkURL.path, withDestinationPath: root.appendingPathComponent("gone").path)
        let model = CommandLineModel(link: link)
        model.install()
        XCTAssertEqual(model.state, .installed)
        model.remove()
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.state, .notInstalled)
    }

    private func pointAtSourceInstall() throws -> String {
        let source = link.home.appendingPathComponent("Library/Application Support/Calopod/Service/bin/calopod")
        try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: source, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(atPath: link.linkURL.path, withDestinationPath: source.path)
        return source.path
    }

    func testSourceLinkIsOfferedAndRelinkedAfterConfirm() throws {
        _ = try pointAtSourceInstall()
        let model = CommandLineModel(link: link)
        XCTAssertTrue(model.offersTakeover)
        model.takeOver()
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.state, .installed)
        XCTAssertFalse(model.offersTakeover)
        model.remove()
        XCTAssertEqual(model.state, .notInstalled)
    }

    func testDecliningLeavesTheSourceLink() throws {
        let source = try pointAtSourceInstall()
        let model = CommandLineModel(link: link)
        model.declineTakeover()
        XCTAssertFalse(model.offersTakeover)
        model.takeOver()
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: link.linkURL.path), source)
    }

    func testFailedLinkKeepsTheOldOne() throws {
        let source = try pointAtSourceInstall()
        let model = CommandLineModel(link: link)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: link.binDirectory.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: link.binDirectory.path) }
        model.takeOver()
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: link.linkURL.path), source)
    }

    func testAnotherLinkIsNotOfferedForTakeover() throws {
        _ = try pointElsewhere()
        let model = CommandLineModel(link: link)
        XCTAssertFalse(model.offersTakeover)
        model.takeOver()
        XCTAssertEqual(model.state, .elsewhere(target: root.appendingPathComponent("source/calopod").standardizedFileURL.path))
    }
}
