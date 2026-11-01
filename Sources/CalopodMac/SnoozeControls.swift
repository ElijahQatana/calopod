import CalopodCommands
import SwiftUI

/// Picks the day a snoozed item comes back, at 8:00.
struct SnoozeDatePicker: View {
    let onPick: (Date) -> Void
    @State private var day = Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()

    private var tomorrow: Date { Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Day", selection: $day, in: tomorrow..., displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
            Button("Snooze until this day") { onPick(day) }.buttonStyle(.accentFilled)
        }
        .padding(14)
    }
}

/// Later today, tomorrow or a date. Nothing is sent to the calendar.
struct SnoozeMenu: View {
    let choose: (InboxSnoozeChoice) -> Void
    @State private var picking = false

    var body: some View {
        Menu("Snooze") {
            Button("Later today") { choose(.laterToday) }
            Button("Tomorrow") { choose(.tomorrow) }
            Button("Pick a date…") { picking = true }
        }
        .help("Hide it until later. Nothing is sent or marked.")
        .popover(isPresented: $picking) {
            SnoozeDatePicker { picking = false; choose(.day($0)) }
        }
    }
}

enum SnoozeText {
    static func until(_ date: Date) -> String {
        "Until " + date.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute())
    }
}
