@testable import CalopodEventKit
import Foundation
import Testing

#if os(macOS)
private func runCodesign(_ arguments: [String]) throws {
    let codesign = Process()
    codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    codesign.arguments = arguments
    codesign.standardError = FileHandle.nullDevice
    try codesign.run()
    codesign.waitUntilExit()
}

private func makeHost(
    in root: URL,
    layout: String,
    identifier: String = EventKitHostSignature.identifier,
    sign: Bool = true
) throws -> URL {
    let app = root.appendingPathComponent("\(layout)/Calopod EventKit Host.app", isDirectory: true)
    let executable = app.appendingPathComponent("Contents/MacOS/CalopodEventKitHost")
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
    let plist: [String: Any] = [
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": "CalopodEventKitHost",
        "CFBundlePackageType": "APPL",
    ]
    try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
    // The copied system binary arrives signed, so unsigned means stripping it.
    try runCodesign(sign ? ["--force", "--sign", "-", app.path] : ["--remove-signature", executable.path])
    return app
}

@Test
func hostSignatureCheckCoversMissingUnsignedWrongIdentifierAndValid() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-host-signature-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = ".build/eventkit-host"

    let valid = try makeHost(in: root.appendingPathComponent("valid"), layout: layout)
    try EventKitHostSignature.verify(appURL: valid)

    #expect(throws: EventKitHostSignatureError.missing) {
        try EventKitHostSignature.verify(appURL: root.appendingPathComponent("none.app"))
    }
    let unsigned = try makeHost(in: root.appendingPathComponent("unsigned"), layout: layout, sign: false)
    #expect(throws: EventKitHostSignatureError.unsigned) {
        try EventKitHostSignature.verify(appURL: unsigned)
    }
    let wrong = try makeHost(
        in: root.appendingPathComponent("wrong"),
        layout: layout,
        identifier: "example.com.other"
    )
    #expect(throws: EventKitHostSignatureError.wrongIdentifier) {
        try EventKitHostSignature.verify(appURL: wrong)
    }

    // A modified bundle no longer matches its signature.
    try Data("changed".utf8).write(to: valid.appendingPathComponent("Contents/Resources-extra"))
    #expect(throws: EventKitHostSignatureError.invalid) {
        try EventKitHostSignature.verify(appURL: valid)
    }
}

@Test
func adHocHostIsAcceptedOnlyInDevelopmentAndInstalledLayouts() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-host-signature-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for layout in [".build/eventkit-host", "Calopod/Service/eventkit-host"] {
        let host = try makeHost(in: root.appendingPathComponent(layout.replacingOccurrences(of: "/", with: "-")), layout: layout)
        try EventKitHostSignature.verify(appURL: host)
    }
    let elsewhere = try makeHost(in: root.appendingPathComponent("elsewhere"), layout: "Downloads")
    #expect(throws: EventKitHostSignatureError.untrusted) {
        try EventKitHostSignature.verify(appURL: elsewhere)
    }
}
#endif
