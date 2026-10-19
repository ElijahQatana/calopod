import CalopodCommands
import Foundation
import Observation

/// Drives the review sheet. The rules live in `InboxReviewService`; this only decides what to show next.
@MainActor
@Observable
final class InboxReviewModel {
    enum Phase {
        case start
        case working(String)
        case card(InboxReviewCardInfo)
        case confirm(InboxReviewCardInfo, ConflictChoice)
        /// Nothing was sent. Offers Refresh, Hold and Stop.
        case problem(String, key: String?)
        case summary
    }

    private(set) var phase = Phase.start {
        // The summary has its own wording, so a leftover step message goes.
        didSet { if case .summary = phase { notice = nil } }
    }
    private(set) var progress: InboxReviewProgress?
    /// A saved review that can be continued.
    private(set) var saved: InboxReviewProgress?
    private(set) var notice: String?
    private(set) var paused = false
    var overlapsOnly = false
    var skipMaybe = false

    /// Events moved on from after being left for the Calendar app. Held, never counted as answered.
    private(set) var calendarSkips = 0
    /// The event whose Calendar link was just opened, so the sheet can offer Done next.
    private(set) var openedKey: String?

    private let service: InboxReviewService
    private let calendar: CalendarOpening
    private var keyboard = ReviewKeyboard()
    private var focus: (key: String, origin: String)?
    private var isWorking: Bool { if case .working = phase { true } else { false } }

    init(service: InboxReviewService = InboxReviewService(), calendar: CalendarOpening = SystemCalendarOpener()) {
        self.service = service
        self.calendar = calendar
    }

    /// True while looking at an overlapping event reached with G.
    var isJumped: Bool { focus != nil }

    var keyboardMode: ReviewKeyboard.Mode? {
        switch phase {
        case .card: .card
        case .confirm: .confirm
        case .problem: .problem
        case .start, .working, .summary: nil
        }
    }

    func open(filter: InboxFilter) {
        notice = nil
        paused = false
        progress = nil
        calendarSkips = 0
        openedKey = nil
        overlapsOnly = filter == .conflicts
        saved = try? service.unfinished()
        phase = .start
    }

    func dismissNotice() { notice = nil }

    // MARK: Starting and resuming

    func begin() async {
        guard !isWorking else { return }
        phase = .working("Getting your queue ready…")
        do {
            progress = try service.start(overlapsOnly: overlapsOnly, skipMaybe: skipMaybe)
            await next()
        } catch {
            fail("The review could not start. Try again.")
        }
    }

    /// Checks any reply with an unknown outcome first. It never sends one again.
    func resume() async {
        guard !isWorking else { return }
        phase = .working(saved?.hasUnclear == true ? "Checking what happened to your last reply…" : "Picking up where you left off…")
        do {
            progress = try await service.resume()
            await next()
        } catch {
            fail("The review could not be resumed. Nothing was sent.")
        }
    }

    // MARK: Keys

    /// What a key press means right now, if anything.
    func interpret(_ text: String) -> ReviewKey? {
        guard let mode = keyboardMode else { return nil }
        return keyboard.press(text, mode: mode)
    }

    func perform(_ key: ReviewKey) async {
        switch (phase, key) {
        case (.card(let card), .reply(let reply)):
            // Only replies offered for this event can be chosen, and each one is confirmed first.
            if card.replies.contains(reply) { notice = nil; phase = .confirm(card, reply) }
        case (.card(let card), .hold):
            await finish(await service.hold(card: card), card: card)
        case (.card(let card), .goTo(let number)):
            guard card.neighbors.indices.contains(number - 1) else { return }
            focus = (card.neighbors[number - 1].id, focus?.origin ?? card.entry.id)
            await next()
        case (.card(let card), .openCalendar) where card.detail.canOpenInCalendar:
            // Nothing is sent. The person answers in Calendar and comes back.
            guard let id = card.detail.calendarEventID else { return }
            let result = calendar.open(eventID: id, startsAt: card.entry.startsAt)
            if result == .opened { openedKey = card.entry.id }
            notice = CalendarOpenText.message(for: result, title: card.entry.title, startsAt: card.entry.startsAt)
        case (.card(let card), .doneInCalendar) where card.isMacCalendar && card.replies.isEmpty:
            let result = await service.hold(card: card)
            if result.0 == .held { calendarSkips += 1 }
            await finish(result, card: card, held: "Left for the Calendar app. Calopod checks it again next time. Nothing was sent.")
        case (.card, .back):
            guard focus != nil else { return }
            focus = nil
            await next()
        case (.confirm(let card, let reply), .send):
            phase = .working("Sending your reply…")
            await finish(await service.reply(reply, card: card), card: card)
        case (.confirm(let card, _), .cancel):
            phase = .card(card)
        case (.problem, .refresh):
            await next()
        case (.problem(_, let key), .hold):
            await holdUnavailable(key)
        case (_, .stop):
            stop()
        default:
            break
        }
    }

    /// Progress is already saved after every step, so stopping only changes what is shown.
    func stop() {
        guard !isWorking else { return }
        paused = progress?.isFinished != true
        phase = .summary
    }

    // MARK: Steps

    private func next() async {
        guard let id = progress?.sessionID else { return fail("No review is open.") }
        phase = .working("Reading the latest from your calendars…")
        do {
            guard let card = try await service.card(sessionID: id, focus: focus?.key, from: focus?.origin) else {
                progress = try service.progress(sessionID: id)
                phase = .summary
                return
            }
            progress = try service.progress(sessionID: id)
            phase = .card(card)
        } catch {
            let key = focus?.key ?? progress?.currentKey
            notice = nil
            phase = .problem("This event changed or could not be opened. Nothing was sent.", key: key)
        }
    }

    private func finish(
        _ result: (InboxReviewStep, InboxReviewProgress?), card: InboxReviewCardInfo,
        held: String = "Held for this session. Nothing was sent."
    ) async {
        let (step, updated) = result
        if let updated { progress = updated }
        switch step {
        case .recorded(let reply):
            notice = "Reply recorded: \(Self.name(reply))."
            focus = nil
            await next()
        case .held:
            notice = held
            focus = nil
            await next()
        case .changed:
            notice = "The event changed first. Nothing was sent. Choose again."
            await next()
        case .busy:
            notice = "A sync is running. Nothing was sent. Try again in a moment."
            phase = .card(card)
        case .failed(let message):
            notice = nil
            phase = .problem(message, key: card.entry.id)
        case .unclear:
            notice = "The outcome is not clear yet. It will not be sent again. Resume checks what happened."
            paused = true
            phase = .summary
        }
    }

    private func holdUnavailable(_ key: String?) async {
        guard let id = progress?.sessionID, let key else { return stop() }
        do {
            progress = try service.holdUnavailable(sessionID: id, key: key)
            notice = "Held for this session. Nothing was sent."
            focus = nil
            await next()
        } catch {
            fail("That could not be held. Stop and resume to check it.")
        }
    }

    private func fail(_ message: String) {
        phase = .problem(message, key: nil)
    }

    static func name(_ reply: ConflictChoice) -> String {
        switch reply {
        case .yes: "Yes"
        case .maybe: "Maybe"
        case .no: "No"
        case .noChange: "Hold"
        }
    }
}
