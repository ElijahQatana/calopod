import Foundation
import Observation
import UIKit
import UserNotifications

enum NotificationPermission: Equatable, Sendable {
    case notDetermined, allowed, denied
    /// No notification center, as in a test run or a fixture launch.
    case unavailable
}

/// The part of the notification center the controller uses, so tests can stand in for it.
protocol ReminderCenter: Sendable {
    func permission() async -> NotificationPermission
    func requestPermission() async -> Bool
    func pendingIDs() async -> [String]
    func add(_ reminder: PlannedReminder) async
    func remove(ids: [String]) async
}

/// Keeps the phone's pending reminders in step with the Mac's last snapshot, and holds the one switch
/// that silences them on this phone. The switch is only on this phone; the times come from the Mac.
@MainActor
@Observable
final class Reminders {
    static let switchKey = "remindersOn"

    private(set) var permission: NotificationPermission = .notDetermined
    /// An event a tapped reminder asked to open. The Calendar tab takes it and clears it.
    var requestedEvent: String?

    var isOn: Bool {
        didSet {
            defaults.set(isOn, forKey: Self.switchKey)
            Task { await reconcile() }
        }
    }

    private let center: (any ReminderCenter)?
    private let defaults: UserDefaults
    private let now: () -> Date
    private var snapshot: Snapshot?
    private var known = false
    private var running = false
    private var again = false
    private var delegate: ReminderDelegate?

    init(center: (any ReminderCenter)?, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.center = center
        self.defaults = defaults
        self.now = now
        permission = center == nil ? .unavailable : .notDetermined
        isOn = defaults.object(forKey: Self.switchKey) as? Bool ?? true
        if center is UserNotificationCenter {
            let delegate = ReminderDelegate(self)
            self.delegate = delegate
            UserNotificationCenter.install(delegate: delegate)
        }
    }

    /// Called after every refresh and when the app comes forward. A Mac that shares nothing clears the
    /// reminders. A phase with no data because nothing could be read leaves the ones already set.
    func update(for phase: SnapshotStore.Phase) async {
        switch phase {
        case .content(let snapshot, _): self.snapshot = snapshot
        case .sharingOff, .nothingPublished: snapshot = nil
        case .loading, .failed, .needsNewerApp, .signedOut: return
        }
        known = true
        await reconcile()
    }

    /// Asks for permission, in answer to the person tapping the button that explains why.
    func requestPermission() async {
        _ = await center?.requestPermission()
        await reconcile()
    }

    func reconcile() async {
        guard let center else { return }
        if running { again = true; return }
        running = true
        repeat {
            again = false
            permission = await center.permission()
            guard known else { continue }
            let wanted = permission == .allowed && isOn ? snapshot.map { ReminderPlan.plan(snapshot: $0, now: now()) } ?? [] : []
            let ours = await center.pendingIDs().filter { $0.hasPrefix(ReminderPlan.idPrefix) }
            let stale = Set(ours).subtracting(wanted.map(\.id))
            if !stale.isEmpty { await center.remove(ids: Array(stale)) }
            for reminder in wanted { await center.add(reminder) }
        } while again
        running = false
    }

    func receive(_ response: ReminderResponse) {
        switch response {
        case .open(let id): requestedEvent = id
        case .join(let url, let id):
            requestedEvent = id
            UIApplication.shared.open(url)
        }
    }
}

/// What a tap on a reminder asks for.
enum ReminderResponse: Equatable, Sendable {
    case open(eventID: String)
    case join(URL, eventID: String)

    static let eventKey = "calopod.event"
    static let joinKey = "calopod.join"
    static let joinAction = "calopod.reminder.action.join"
    static let openAction = "calopod.reminder.action.open"

    /// A tap on the notification itself, or Open, opens the event. Join opens the meeting, or the event
    /// when the link is not usable. Dismissing does nothing.
    static func parse(actionIdentifier: String, info: [String: String]) -> ReminderResponse? {
        guard let eventID = info[eventKey] else { return nil }
        switch actionIdentifier {
        case joinAction:
            if let text = info[joinKey], let url = ReminderPlan.webLink(text) { return .join(url, eventID: eventID) }
            return .open(eventID: eventID)
        case UNNotificationDefaultActionIdentifier, openAction:
            return .open(eventID: eventID)
        default:
            return nil
        }
    }
}

final class ReminderDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private weak var reminders: Reminders?

    @MainActor init(_ reminders: Reminders) { self.reminders = reminders }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// The completion handler form, finished on the main thread. UIKit asserts when an action that opens the
    /// app completes anywhere else, which the async form did.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        receive(response, finishing: completionHandler)
    }

    private struct Completion: @unchecked Sendable { let finish: () -> Void }

    private func receive(_ response: UNNotificationResponse, finishing handler: @escaping () -> Void) {
        let info = (response.notification.request.content.userInfo as? [String: String]) ?? [:]
        let parsed = ReminderResponse.parse(actionIdentifier: response.actionIdentifier, info: info)
        let completion = Completion(finish: handler)
        DispatchQueue.main.async { [weak reminders] in
            if let parsed { MainActor.assumeIsolated { reminders?.receive(parsed) } }
            completion.finish()
        }
    }
}

struct UserNotificationCenter: ReminderCenter {
    private var center: UNUserNotificationCenter { .current() }

    /// Sets the handler and the Join and Open actions.
    @MainActor static func install(delegate: ReminderDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let join = UNNotificationAction(identifier: ReminderResponse.joinAction, title: "Join", options: [.foreground])
        let open = UNNotificationAction(identifier: ReminderResponse.openAction, title: "Open in Calopod", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ReminderPlan.joinCategory, actions: [join, open], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: ReminderPlan.openCategory, actions: [open], intentIdentifiers: [], options: []),
        ])
    }

    func permission() async -> NotificationPermission {
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

    func pendingIDs() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func add(_ reminder: PlannedReminder) async {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.threadIdentifier = "calopod.event." + reminder.eventID
        content.categoryIdentifier = reminder.category
        content.interruptionLevel = .active
        var info = [ReminderResponse.eventKey: reminder.eventID]
        info[ReminderResponse.joinKey] = reminder.joinURL?.absoluteString
        content.userInfo = info
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(parts, from: reminder.fireDate), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }

    func remove(ids: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
