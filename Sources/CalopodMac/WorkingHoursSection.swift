import CalopodStore
import SwiftUI

/// Working hours in Settings: for each weekday, whether it is a working day and when it starts and ends.
struct WorkingHoursSection: View {
    let model: WorkingHoursModel

    var body: some View {
        CardSection("Working hours", footnote: footnote) {
            ForEach(1...7, id: \.self) { weekday in row(weekday) }
            focusRow
            if let notice = model.notice { CardRow { Banner(kind: .caution, text: notice) } }
        }
        .onAppear { model.reload() }
    }

    private var footnote: String {
        "Availability counts free time only inside these hours, in your local time zone. Busy time outside them is still shown. "
            + "Availability flags days with no free stretch as long as the focus time. The command line can change both with calopod hours."
    }

    private var focusRow: some View {
        CardRow("Focus time") {
            Stepper(
                EventDuration.text(model.focus.seconds),
                value: Binding(get: { model.focus.minutes }, set: { model.setFocus(minutes: $0) }),
                in: FocusSettings.minutes, step: 15)
        }
    }

    private func row(_ weekday: Int) -> some View {
        let name = Calendar.current.weekdaySymbols[weekday % 7]
        let day = model.hours.day(isoWeekday: weekday)
        return CardRow(name) {
            HStack(spacing: 12) {
                if let day {
                    picker("\(name) start", minute: day.startMinute) { model.setStart($0, isoWeekday: weekday) }
                    Text("to").foregroundStyle(.secondary)
                    picker("\(name) end", minute: day.endMinute) { model.setEnd($0, isoWeekday: weekday) }
                } else {
                    Text("Day off").foregroundStyle(.secondary)
                }
                Toggle("\(name) is a working day", isOn: Binding(
                    get: { day != nil }, set: { model.setWorking($0, isoWeekday: weekday) }))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private func picker(_ label: String, minute: Int, set: @escaping (Int) -> Void) -> some View {
        DatePicker(label, selection: Binding(get: { Self.date(minute) }, set: { set(Self.minute($0)) }), displayedComponents: .hourAndMinute)
            .labelsHidden()
    }

    /// 24:00 cannot be shown by a time picker, so it appears as the last minute of the day.
    static func date(_ minute: Int, calendar: Calendar = .current) -> Date {
        let shown = min(minute, 1439)
        return calendar.date(bySettingHour: shown / 60, minute: shown % 60, second: 0, of: calendar.startOfDay(for: Date())) ?? Date()
    }

    static func minute(_ date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
