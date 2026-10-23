import Foundation
import Testing

@testable import CalopodProviders

@Suite("Update check")
struct UpdateCheckTests {
    struct Canned: HTTPTransport {
        var status = 200
        var body = Data()
        var fails = false

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            if fails { throw ProviderFailure.invalidResponse }
            return HTTPResponse(statusCode: status, body: body)
        }
    }

    private static let page = "https://github.com/ElijahQatana/calopod/releases/tag/"

    private func releases(_ items: [(tag: String, draft: Bool, url: String?)]) -> Data {
        let rows = items.map { "{\"tag_name\":\"\($0.tag)\",\"draft\":\($0.draft),\"html_url\":\"\($0.url ?? Self.page + $0.tag)\"}" }
        return Data("[\(rows.joined(separator: ","))]".utf8)
    }

    private func check(_ current: String, _ transport: Canned) async -> UpdateResult {
        await UpdateCheck(transport: transport).check(current: current)
    }

    @Test("Versions compare by number, and a suffix sorts below the plain release", arguments: [
        ("1.0.1", "1.0.2", true), ("1.0.2", "1.0.2", false), ("1.0.10", "1.0.9", false), ("1.9.0", "1.10.0", true),
        ("1.1.0-rc1", "1.1.0", true), ("1.1.0", "1.1.0-rc1", false), ("v2.0.0", "1.9.9", false), ("1.1", "1.1.0", false),
    ])
    func compare(older: String, newer: String, isLess: Bool) throws {
        #expect((try #require(ReleaseVersion(older)) < #require(ReleaseVersion(newer))) == isLess)
    }

    @Test("Text that is not a version is refused", arguments: ["", "latest", "1.x.0", "1.0.0.0", "1.0.0-"])
    func refuses(text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test("The newest release is offered, with pre-releases counted and drafts skipped")
    func offersNewest() async {
        let body = releases([("v1.0.2", false, nil), ("v1.0.3", true, nil), ("v1.0.1", false, nil)])
        #expect(await check("1.0.1", Canned(body: body)) == .available(version: "1.0.2", page: URL(string: Self.page + "v1.0.2")!))
    }

    @Test("Nothing is offered when the running version is the newest or newer")
    func upToDate() async {
        let body = releases([("v1.0.1", false, nil)])
        #expect(await check("1.0.1", Canned(body: body)) == .upToDate)
        #expect(await check("1.0.2", Canned(body: body)) == .upToDate)
        #expect(await check("1.0.1", Canned(body: releases([]))) == .upToDate)
    }

    @Test("A release page outside the project is ignored")
    func foreignLink() async {
        let body = releases([("v9.0.0", false, "https://example.com/releases/v9.0.0")])
        #expect(await check("1.0.1", Canned(body: body)) == .upToDate)
    }

    @Test("A failed request says why", arguments: [
        (Canned(fails: true), "reach"), (Canned(status: 403), "limiting"), (Canned(status: 500), "error (500)"),
        (Canned(body: Data("{}".utf8)), "expected"),
    ])
    func failures(transport: Canned, words: String) async {
        guard case let .failed(reason) = await check("1.0.1", transport) else {
            Issue.record("Expected a failure")
            return
        }
        #expect(reason.contains(words))
    }
}
