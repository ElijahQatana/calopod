import CalopodCommands
import CalopodRuntime
import Foundation
import Observation

@MainActor
@Observable
final class InboxModel {
    private(set) var board: InboxBoard?
    private(set) var detail: InboxDetail?
    private(set) var busy: String?
    private(set) var notice: String?
    /// The notice text that is a pointer to the event in Calendar rather than a problem.
    private(set) var calendarHint: String?
    var noticeIsHint: Bool { notice != nil && notice == calendarHint }
    private(set) var result: InboxReplyResult?
    /// A reply waiting for the person to confirm it. Nothing is sent until then.
    private(set) var pendingReply: ConflictChoice?
    var selection: String? {
        didSet { if selection != oldValue { result = nil; pendingReply = nil; Task { await loadDetail() } } }
    }

    let review = InboxReviewModel()
    private let service: InboxScreenService
    private let send: @Sendable (String, ConflictChoice) async -> InboxReplyResult
    private let calendar: CalendarOpening
    private let afterSend: (@MainActor () async -> Void)?
    private let readDetail: @Sendable (String) throws -> InboxDetail
    private var loads = 0
    private var loadFailed = false

    /// `send`, `afterSend` and `readDetail` let tests stand in for the calendar and the local reads.
    init(
        service: InboxScreenService = InboxScreenService(),
        send: (@Sendable (String, ConflictChoice) async -> InboxReplyResult)? = nil,
        afterSend: (@MainActor () async -> Void)? = nil,
        readDetail: (@Sendable (String) throws -> InboxDetail)? = nil,
        calendar: CalendarOpening = SystemCalendarOpener()
    ) {
        self.calendar = calendar
        self.service = service
        self.readDetail = readDetail ?? { try service.detail(for: $0) }
        self.send = send ?? { await service.reply(to: $0, $1) }
        self.afterSend = afterSend
    }

    var isBusy: Bool { busy != nil }
    /// What the sidebar badge shows: everything that needs attention.
    var count: Int { board?.entries.count ?? 0 }

    /// Clears the error banner. Also used when the screen is left.
    func dismissNotice() {
        notice = nil
        loadFailed = false
    }

    func reload() async {
        let service = service
        loads += 1
        let load = loads
        do {
            let loaded = try await Task.detached { try service.board() }.value
            // Several screens reload at once; an older read must not replace a newer one.
            if load == loads, board != loaded { board = loaded }
            // A load error goes away once a load works; other notices are left alone.
            if loadFailed { notice = nil; loadFailed = false }
        } catch {
            notice = "The inbox could not be loaded. Try again."
            loadFailed = true
        }
        if let selection, board?.entries.contains(where: { $0.id == selection }) != true {
            // Clearing the selection already clears the detail.
            self.selection = nil
        } else {
            await loadDetail()
        }
    }

    /// Keeps a valid event selected within the visible list.
    func ensureSelection(in entries: [InboxEntry]) {
        if selection == nil || !entries.contains(where: { $0.id == selection }) { selection = entries.first?.id }
    }

    func refresh() async {
        guard busy == nil else { return }
        let service = service
        busy = "Refreshing calendars…"
        notice = nil
        do {
            try await Task.detached { try await service.refresh() }.value
        } catch CalopodRuntimeError.busy {
            notice = "A sync is running. Try again in a moment."
        } catch {
            notice = "Some calendars could not be refreshed. What you see may be out of date."
        }
        busy = nil
        await reload()
    }

    /// Clicking Yes, Maybe or No only asks. The reply goes out from `confirmReply`.
    func askToReply(_ choice: ConflictChoice) {
        guard busy == nil, selection != nil, choice != .noChange else { return }
        pendingReply = choice
    }

    func cancelReply() { pendingReply = nil }

    func confirmReply() async {
        guard let choice = pendingReply else { return }
        pendingReply = nil
        await reply(choice)
    }

    private func reply(_ choice: ConflictChoice) async {
        guard busy == nil, let id = selection else { return }
        let send = send
        busy = "Sending your reply…"
        notice = nil
        let outcome = await Task.detached { await send(id, choice) }.value
        busy = nil
        if let afterSend { await afterSend() } else { await reload() }
        result = outcome
    }

    func acknowledge(_ entry: InboxEntry) async {
        guard busy == nil else { return }
        let service = service
        busy = "Marking as seen…"
        notice = nil
        do {
            try await Task.detached { try service.acknowledge(revisionID: entry.revisionID) }.value
        } catch {
            notice = "That change could not be marked as seen. It may have changed again."
        }
        busy = nil
        await reload()
    }

    /// Opens the event in the Calendar app. This is not a reply and changes nothing in the inbox.
    func openInCalendar() {
        guard let detail, let id = detail.calendarEventID else { return }
        let startsAt = detail.entry.startsAt
        let result = calendar.open(eventID: id, startsAt: startsAt)
        notice = CalendarOpenText.message(for: result, title: detail.entry.title, startsAt: startsAt)
        calendarHint = result == .opened ? notice : nil
    }

    /// Moves on without replying or changing anything.
    func hold(in entries: [InboxEntry]) {
        guard let index = entries.firstIndex(where: { $0.id == selection }) else { return }
        let next = entries.indices.contains(index + 1) ? index + 1 : 0
        selection = entries[next].id
    }

    private func loadDetail() async {
        guard let id = selection else { detail = nil; return }
        let readDetail = readDetail
        let loaded = try? await Task.detached { try readDetail(id) }.value
        if selection == id, detail != loaded { detail = loaded }
    }
}
