import CalopodCommands
import CalopodDomain
import Foundation
import Observation

@MainActor
@Observable
final class SetupModel {
    private(set) var snapshot: SetupSnapshot?
    private(set) var busy: String?
    private(set) var notice: String?
    private var loadFailed = false

    private let service: SetupService
    @ObservationIgnored let aliases: CalendarAliases

    @ObservationIgnored private let colors: CalendarColors

    init(service: SetupService = SetupService(), aliases: CalendarAliases = .shared, colors: CalendarColors = .shared) {
        self.service = service
        self.aliases = aliases
        self.colors = colors
    }

    var isBusy: Bool { busy != nil }

    /// Every calendar that is a source, ignored or not: they all still sync.
    var selectedCalendars: [(id: String, title: String, isReadOnly: Bool)] {
        (snapshot?.connections ?? []).flatMap { connection in
            connection.calendars.filter(\.isSelected).map {
                (id: $0.id, title: "\(connection.label) · \(aliases.name(for: $0))", isReadOnly: $0.isReadOnly)
            }
        }
    }

    /// Writable calendars that are not sources, which is what calopod-setup offers as targets.
    var targetCandidates: [(id: String, title: String)] {
        (snapshot?.connections ?? []).flatMap { connection in
            connection.calendars.filter { !$0.isSelected && !$0.isReadOnly && !aliases.isIgnored($0.id) }.map {
                (id: $0.id, title: "\(connection.label) · \(aliases.name(for: $0))")
            }
        }
    }

    /// Calendars any arm reads from or writes to.
    var armCalendarIDs: Set<String> {
        Set((snapshot?.arms ?? []).flatMap { $0.sourceIDs + [$0.targetID] })
    }

    func isInUse(_ calendar: SetupCalendar) -> Bool {
        CalendarAliases.isInUse(calendar.id, selected: calendar.isSelected, armCalendars: armCalendarIDs)
    }

    /// Names for an arm's route, with local aliases applied.
    func sourceNames(of arm: SetupArm) -> [String] {
        zip(arm.sourceIDs, arm.sourceNames).map { aliases.name(for: $0, real: $1) }
    }

    func targetName(of arm: SetupArm) -> String { aliases.name(for: arm.targetID, real: arm.targetName) }

    var fullDetailsArm: SetupArm? { snapshot?.arms.first { $0.rule == .fullDetails } }
    var busyArm: SetupArm? { snapshot?.arms.first { $0.rule == .busy && $0.isEnabled } }

    func reload() async {
        let service = service
        do {
            let loaded = try await Task.detached { try service.snapshot() }.value
            snapshot = loaded
            if loadFailed { notice = nil; loadFailed = false }
            // Every screen shows calendar colors, so they are given out as soon as calendars are known.
            colors.assignMissing(
                to: loaded.connections.flatMap { connection in
                    connection.calendars.map {
                        CalendarColorSource(id: $0.id, providerColor: $0.providerColor, provider: connection.provider)
                    }
                },
                ignoring: aliases.ignored)
        } catch {
            notice = service.message(for: error)
            loadFailed = true
        }
    }

    func connect(_ provider: SetupProvider) async {
        let service = service
        await run(provider == .mac ? "Waiting for Calendar access…" : "Waiting for browser sign-in…") {
            try await service.connect(provider)
        }
    }

    func refresh(_ connectionID: String) async {
        let service = service
        await run("Refreshing calendars…") { try await service.refresh(connectionID: connectionID) }
    }

    func disconnect(_ connectionID: String) async {
        let service = service
        await run("Removing Connection…") { try service.disconnect(connectionID: connectionID) }
    }

    func setSelected(_ calendarID: String, _ selected: Bool) async {
        let service = service
        await run(nil) { try service.setSelected(calendarID: calendarID, selected: selected) }
    }

    func setUpTwoArms(sources: [String], fullDetailsTarget: String?, busyTarget: String?) async {
        let service = service
        await run("Saving…") {
            try service.setUpTwoArms(
                sourceIDs: sources, fullDetailsTargetID: fullDetailsTarget, busyTargetID: busyTarget)
        }
    }

    func addArm(sources: [String], target: String, rule: ArmRuleMode, name: String?) async {
        let service = service
        await run("Saving…") {
            try service.addArm(sourceIDs: sources, targetID: target, rule: rule, name: name)
        }
    }

    func setRule(_ armID: String, _ rule: ArmRuleMode) async {
        let service = service
        await run(nil) { try service.setRule(armID: armID, rule: rule) }
    }

    func setArmEnabled(_ armID: String, _ enabled: Bool) async {
        let service = service
        await run(nil) { try service.setArmEnabled(armID: armID, enabled: enabled) }
    }

    /// Returns a short message when the name is refused, nil when it was saved.
    func renameArm(_ armID: String, to name: String) async -> String? {
        guard busy == nil else { return "Wait for the current change to finish." }
        let service = service
        do {
            try await Task.detached { try service.renameArm(armID: armID, name: name) }.value
        } catch {
            return service.message(for: error)
        }
        await reload()
        return nil
    }

    func removeArm(_ armID: String) async {
        let service = service
        await run("Removing…") { try service.removeArm(armID: armID) }
    }

    private func run(
        _ label: String?,
        _ work: @escaping @Sendable () async throws -> Void
    ) async {
        guard busy == nil else {
            notice = "Wait for the current change to finish, then try again."
            return
        }
        busy = label ?? "Saving…"
        notice = nil
        do {
            try await Task.detached { try await work() }.value
        } catch {
            notice = service.message(for: error)
        }
        busy = nil
        await reload()
    }
}
