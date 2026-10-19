import CalopodCommands
import CalopodDomain
import CalopodRuntime
import Foundation
import UserNotifications

/// What a click on a reminder asks for.
enum ReminderResponse: Equatable, Sendable {
    case open(eventID: String)
    case join(MeetingLink, eventID: String)

    static let eventKey = "calopod.event"
    static let joinKey = "calopod.join"

    /// A click on the notification itself, or Open in Calopod, opens the event. Join opens the meeting,
    /// or the event when the link is no longer usable. Dismissing does nothing.
    static func parse(actionIdentifier: String, info: [String: String]) -> ReminderResponse? {
        guard let eventID = info[eventKey] else { return nil }
        switch actionIdentifier {
        case ReminderActionID.join:
            if let web = info[joinKey], let link = MeetingLink.first(in: web) { return .join(link, eventID: eventID) }
            return .open(eventID: eventID)
        case UNNotificationDefaultActionIdentifier, ReminderActionID.open:
            return .open(eventID: eventID)
        default:
            return nil
        }
    }
}

/// Takes clicks on reminders. Join runs at once. Opening an event waits until the app has its schedule
/// loaded, so a click that launched the app lands on the event once it is ready.
@MainActor
final class ReminderRouter {
    static let shared = ReminderRouter()

    private let joiner: any MeetingJoining
    private var openEvent: (@MainActor (String) -> Void)?
    private var queued: String?

    init(joiner: any MeetingJoining = MeetingJoiner.system) { self.joiner = joiner }

    func receive(_ response: ReminderResponse) {
        switch response {
        case .join(let link, _):
            let joiner = joiner
            Task { _ = await joiner.join(link) }
        case .open(let id):
            if let openEvent { openEvent(id) } else { queued = id }
        }
    }

    /// Called once the schedule is loaded. Anything clicked before then is delivered now.
    func attach(open: @escaping @MainActor (String) -> Void) {
        openEvent = open
        if let id = queued {
            queued = nil
            open(id)
        }
    }
}

/// The macOS side: the real center, the categories and the click handler.
final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let info = (response.notification.request.content.userInfo as? [String: String]) ?? [:]
        guard let parsed = ReminderResponse.parse(actionIdentifier: action, info: info) else { return }
        await MainActor.run { ReminderRouter.shared.receive(parsed) }
    }
}

enum AppNotifications {
    /// The center only exists for a bundled app; a build folder run or a test run has none.
    static var isAvailable: Bool {
        !RunningUnderTests.isActive && Bundle.main.bundleURL.pathExtension == "app"
    }

    private static let delegate = ReminderNotificationDelegate()

    /// Sets the click handler and the actions. Called when the app delegate is created, before any scene.
    static func install() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let join = UNNotificationAction(identifier: ReminderActionID.join, title: "Join", options: [])
        let open = UNNotificationAction(identifier: ReminderActionID.open, title: "Open in Calopod", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ReminderCategory.join, actions: [join, open], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: ReminderCategory.open, actions: [open], intentIdentifiers: [], options: []),
        ])
    }

    static var live: (any ReminderCenter)? { isAvailable ? UserNotificationCenter() : nil }

    static func permission() async -> NotificationPermissionState {
        await live?.permission() ?? .unavailable
    }

    static func requestPermission() async -> Bool {
        await live?.requestPermission() ?? false
    }
}

struct UserNotificationCenter: ReminderCenter {
    private var center: UNUserNotificationCenter { .current() }

    func permission() async -> NotificationPermissionState {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func pending() async -> [PendingReminder] {
        await center.pendingNotificationRequests().map {
            PendingReminder(id: $0.identifier, fingerprint: $0.content.userInfo[Self.fingerprintKey] as? String)
        }
    }

    func add(_ reminder: PlannedReminder) async {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.threadIdentifier = reminder.threadID
        content.categoryIdentifier = reminder.category
        content.interruptionLevel = .active
        var info = [ReminderResponse.eventKey: reminder.eventID, Self.fingerprintKey: reminder.fingerprint]
        info[ReminderResponse.joinKey] = reminder.joinURL
        content.userInfo = info
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(parts, from: reminder.fireDate), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }

    func remove(ids: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    static let fingerprintKey = "calopod.fingerprint"
}

/// Where Open in Calopod goes: the same place as the menu bar Next card, which is the event in Calendar.
@MainActor
enum ReminderNavigation {
    static func open(
        _ eventID: String, schedule: CalendarModel, navigation: AppNavigation,
        show: () -> Void = { MainWindowOpener.shared.bringForward() }
    ) {
        if let event = schedule.schedule?.events.first(where: { $0.id == eventID && !$0.isCopy }) {
            navigation.openCalendar(showing: event, in: schedule)
        } else {
            navigation.selection = .calendar
        }
        show()
    }
}
