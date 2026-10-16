import CalopodCommands

enum ReviewKey: Equatable {
    case reply(ConflictChoice)
    case hold, stop, back, refresh
    /// For events answered in the Calendar app: open it, or move on once answered there.
    case openCalendar, doneInCalendar
    case goTo(Int)
    case send, cancel
}

/// Turns key presses into review commands. G waits for a number.
struct ReviewKeyboard {
    enum Mode { case card, confirm, problem }

    static let returnKey = "\r"
    static let escapeKey = "\u{1b}"

    private var waitingForNumber = false

    /// Returns nil for a key that means nothing here. Sending needs Return in the confirm step,
    /// so a stray Y, N or M can never send a reply.
    mutating func press(_ text: String, mode: Mode) -> ReviewKey? {
        let key = text.lowercased()
        defer { if key != "g" { waitingForNumber = false } }
        switch mode {
        case .confirm:
            return switch key {
            case Self.returnKey: .send
            case Self.escapeKey, "b": .cancel
            default: nil
            }
        case .problem:
            return switch key {
            case "r": .refresh
            case "h": .hold
            case "s", "q": .stop
            default: nil
            }
        case .card:
            if waitingForNumber, let number = Int(key), number > 0 { return .goTo(number) }
            if key == "g" { waitingForNumber = true; return nil }
            return switch key {
            case "y": .reply(.yes)
            case "n": .reply(.no)
            case "m": .reply(.maybe)
            case "h": .hold
            case "o": .openCalendar
            case "d": .doneInCalendar
            case "b": .back
            case "s", "q": .stop
            default: nil
            }
        }
    }
}
