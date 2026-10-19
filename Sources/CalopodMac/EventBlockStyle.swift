import CalopodCommands
import SwiftUI

/// How an event block looks. One place decides it from (isCopy, copyMode, response), so the
/// week grid, the Inbox day strip and the words for VoiceOver agree.
struct EventBlockStyle: Equatable {
    enum Base: Equatable {
        /// Accepted, maybe, or your own.
        case plain
        case needsRSVP
        /// A full details copy Calopod made.
        case copyFull
        /// A Busy copy Calopod made.
        case copyBusy
    }

    let base: Base
    /// Diagonal lines. Only for an answer of declined, on an event or on a copy of one.
    let hatched: Bool
    /// A declined event fades. A copy never does, so it cannot be mistaken for one.
    let faded: Bool

    var isCopy: Bool { base == .copyFull || base == .copyBusy }

    static func of(isCopy: Bool, copyMode: ScheduleCopyMode?, response: ScheduleResponse) -> EventBlockStyle {
        if isCopy {
            // A copy with no known mode is drawn as Busy: quiet, and nothing is claimed about its details.
            let full = copyMode == .fullDetails
            return EventBlockStyle(base: full ? .copyFull : .copyBusy, hatched: full && response == .declined, faded: false)
        }
        switch response {
        case .needsResponse: return EventBlockStyle(base: .needsRSVP, hatched: false, faded: false)
        case .declined: return EventBlockStyle(base: .plain, hatched: true, faded: true)
        default: return EventBlockStyle(base: .plain, hatched: false, faded: false)
        }
    }

    static func of(_ event: ScheduleEvent) -> EventBlockStyle {
        of(isCopy: event.isCopy, copyMode: event.copyOrigin?.mode, response: event.carriedResponse)
    }
}

/// The words for copies and for the answer they carry, shared by the inspector, the grid and VoiceOver.
enum CopyWords {
    static func kind(_ event: ScheduleEvent) -> String {
        switch event.copyOrigin?.mode {
        case .fullDetails: "Full details copy"
        case .busy: "Busy copy"
        case nil: "Copy"
        }
    }

    static func response(_ response: ScheduleResponse) -> String? {
        switch response {
        case .needsResponse: "Needs RSVP"
        case .accepted: "Accepted"
        case .tentative: "Maybe"
        case .declined: "Declined"
        case .organizer: "You organize"
        case .none: nil
        }
    }

    /// "Full details copy · Accepted". The answer is left out when it is not known.
    static func chip(_ event: ScheduleEvent) -> String {
        [kind(event), response(event.carriedResponse)].compactMap { $0 }.joined(separator: " · ")
    }

    /// What a person should do about a copy, by what it is.
    static func replyHint(_ event: ScheduleEvent) -> String {
        switch event.copyOrigin?.mode {
        case .fullDetails: "This is a copy Calopod made. Reply on the original event."
        case .busy: "This copy only shows that you are busy. Reply on the original event."
        case nil: "This is a copy Calopod made. Reply on the original event."
        }
    }

    static func provenance(_ origin: ScheduleCopyOrigin, calendarName: String) -> String {
        "Copied from \(calendarName) by \(origin.armName)"
    }
}

extension View {
    /// The fill behind an event block. Plain events and needs-RSVP blocks keep their look; a copy gets a
    /// lighter fill with a thin dashed outline; declined answers add the hatch on top.
    @ViewBuilder
    func eventFill(_ style: EventBlockStyle, color: Color, shape: RoundedRectangle) -> some View {
        switch style.base {
        case .needsRSVP:
            background(shape.fill(Theme.pane))
                .overlay { shape.inset(by: 0.75).strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
        case .plain:
            background(shape.fill(Theme.pane))
                .overlay { shape.fill(color.opacity(0.22)).declinedHatch(style.hatched, color: color) }
                .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        case .copyFull, .copyBusy:
            background(shape.fill(Theme.pane))
                .overlay { shape.fill(color.opacity(0.1)).declinedHatch(style.hatched, color: color) }
                .overlay { shape.inset(by: 0.5).strokeBorder(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
        }
    }
}
