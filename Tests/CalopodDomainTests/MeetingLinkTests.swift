import CalopodDomain
import Foundation
import Testing

@Suite("Meeting links")
struct MeetingLinkTests {
    private func find(_ text: String) -> MeetingLink? { MeetingLink.first(in: text) }

    @Test("Each provider and link format is recognized", arguments: [
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%22t%22%7d", MeetingProvider.teams),
        ("https://teams.microsoft.com/meet/1234567890?p=abc", .teams),
        ("https://teams.live.com/meet/9876543210?p=abc", .teams),
        ("https://zoom.us/j/123456789?pwd=abc123", .zoom),
        ("https://us02web.zoom.us/j/123456789", .zoom),
        ("https://example.zoom.us/my/someroom", .zoom),
        ("https://meet.google.com/abc-defg-hij", .meet),
        ("https://meet.google.com/abc-defg-hij?authuser=1", .meet),
        ("https://example.webex.com/meet/someroom", .webex),
        ("https://example.webex.com/example/j.php?MTID=m123", .webex),
        ("https://example.webex.com/join/someroom", .webex),
    ])
    func providers(link: String, provider: MeetingProvider) throws {
        let found = try #require(find(link))
        #expect(found.provider == provider)
        #expect(found.webURL.scheme == "https")
        #expect(found.buttonTitle == "Join \(provider.displayName)")
    }

    @Test("Display names")
    func names() {
        #expect(MeetingProvider.allCases.map(\.displayName) == ["Teams", "Zoom", "Meet", "Webex"])
    }

    @Test("Lookalike hosts, other schemes and other paths are rejected", arguments: [
        "https://zoom.us.example.com/j/123456789",
        "https://teams.microsoft.com.example.net/l/meetup-join/abc",
        "https://notzoom.us/j/123456789",
        "https://example.com/zoom.us/j/123456789",
        "https://zoom.us@example.com/j/123456789",
        "https://meet.google.com.example.org/abc-defg-hij",
        "https://evil-webex.com/meet/someroom",
        "http://zoom.us/j/123456789",
        "zoommtg://zoom.us/join?confno=123456789",
        "https://zoom.us:8443/j/123456789",
        "https://teams.microsoft.com/",
        "https://meet.google.com/landing",
        "https://example.com/",
    ])
    func rejected(link: String) {
        #expect(find(link) == nil)
    }

    @Test("Wrapping and punctuation are stripped")
    func wrapping() throws {
        let cases = [
            "<https://zoom.us/j/123456789?pwd=abc>",
            "Join: https://zoom.us/j/123456789?pwd=abc.",
            "(https://zoom.us/j/123456789?pwd=abc),",
            "see \"https://zoom.us/j/123456789?pwd=abc\" now",
            "<a href=\"https://zoom.us/j/123456789?pwd=abc\">link</a>",
            "[Join](https://zoom.us/j/123456789?pwd=abc);",
            "line one\nhttps://zoom.us/j/123456789?pwd=abc!\nline three",
        ]
        for text in cases {
            #expect(try #require(find(text)).webURL.absoluteString == "https://zoom.us/j/123456789?pwd=abc", "\(text)")
        }
    }

    @Test("A percent encoded link is decoded once")
    func encoded() throws {
        let found = try #require(find("Join https%3A%2F%2Fmeet.google.com%2Fabc-defg-hij today"))
        #expect(found.provider == .meet)
        #expect(found.webURL.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test("Escapes inside a plain link are left alone")
    func keepsEscapes() throws {
        let link = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"
        #expect(try #require(find(link)).webURL.absoluteString == link)
    }

    @Test("HTML ampersands are unescaped")
    func ampersands() throws {
        let found = try #require(find("https://zoom.us/j/123456789?a=1&amp;pwd=abc"))
        #expect(found.webURL.absoluteString == "https://zoom.us/j/123456789?a=1&pwd=abc")
    }

    @Test("The URL field wins over the location, and the location over the notes")
    func preference() throws {
        let teams = "https://teams.microsoft.com/l/meetup-join/abc"
        let zoom = "https://zoom.us/j/123456789"
        let meet = "https://meet.google.com/abc-defg-hij"
        #expect(MeetingLink.find(url: teams, location: zoom, notes: meet)?.provider == .teams)
        #expect(MeetingLink.find(url: nil, location: zoom, notes: meet)?.provider == .zoom)
        #expect(MeetingLink.find(url: "https://example.com/agenda", location: "Room 4", notes: "\(meet) and \(zoom)")?.provider == .meet)
        #expect(MeetingLink.find(url: "", location: "", notes: "no link here") == nil)
        #expect(MeetingLink.find(url: nil, location: nil, notes: nil) == nil)
    }

    @Test("Other links in the notes are skipped")
    func skipsOtherLinks() throws {
        let found = try #require(MeetingLink.find(url: nil, location: nil, notes: "Agenda https://example.com/doc then https://zoom.us/j/123456789"))
        #expect(found.provider == .zoom)
    }

    @Test("Teams app link keeps the path and query")
    func teamsApp() throws {
        let found = try #require(find("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x"))
        #expect(found.appURL?.absoluteString == "msteams://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x")
    }

    @Test("Zoom app link carries the id and password")
    func zoomApp() throws {
        let withPassword = try #require(find("https://us02web.zoom.us/j/123456789?pwd=abc123&uname=x"))
        #expect(withPassword.appURL?.absoluteString == "zoommtg://us02web.zoom.us/join?confno=123456789&pwd=abc123")
        let without = try #require(find("https://zoom.us/j/123456789"))
        #expect(without.appURL?.absoluteString == "zoommtg://zoom.us/join?confno=123456789")
    }

    @Test("Zoom has no app link when the id cannot be read")
    func zoomWithoutID() throws {
        #expect(try #require(find("https://zoom.us/my/someroom")).appURL == nil)
        #expect(try #require(find("https://zoom.us/j/abc")) .appURL == nil)
    }

    @Test("Meet and Webex open on the web")
    func webOnly() throws {
        #expect(try #require(find("https://meet.google.com/abc-defg-hij")).appURL == nil)
        #expect(try #require(find("https://example.webex.com/meet/someroom")).appURL == nil)
    }

    @Test("Join stands out for events on now or soon")
    func near() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func near(_ start: Double, _ end: Double) -> Bool {
            MeetingLink.isNear(startsAt: now.addingTimeInterval(start * 3600), endsAt: now.addingTimeInterval(end * 3600), now: now)
        }
        #expect(near(0, 1))
        #expect(near(-3, 1))
        #expect(near(11, 12))
        #expect(near(-0.5, -0.25))
        #expect(!near(13, 14))
        #expect(!near(-5, -4))
    }

    @Test("The Next surfaces fill Join for events on now or within ten minutes")
    func imminent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func imminent(_ start: Double, _ end: Double) -> Bool {
            MeetingLink.isImminent(startsAt: now.addingTimeInterval(start * 60), endsAt: now.addingTimeInterval(end * 60), now: now)
        }
        #expect(imminent(-5, 25))
        #expect(imminent(10, 40))
        #expect(!imminent(11, 40))
        #expect(!imminent(-40, 0))
    }
}
