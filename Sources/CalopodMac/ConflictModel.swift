import CalopodCommands
import Foundation
import Observation

@MainActor
@Observable
final class ConflictModel {
    private(set) var board: ConflictBoard?
    private(set) var selections: [String: ConflictChoice] = [:]
    private(set) var preview: ConflictPreviewSummary?
    private(set) var report: ConflictApplyReport?
    private(set) var busy: String?
    private(set) var notice: String?

    private let service = ConflictResolutionService()

    var isBusy: Bool { busy != nil }

    /// Everything chosen so far that would send a reply.
    var pendingReplies: [ConflictSelection] {
        selections.compactMap { $0.value == .noChange ? nil : ConflictSelection(eventID: $0.key, choice: $0.value) }
            .sorted { $0.eventID < $1.eventID }
    }

    func choice(for eventID: String) -> ConflictChoice { selections[eventID] ?? .noChange }

    func select(_ choice: ConflictChoice, for eventID: String) {
        selections[eventID] = choice
        preview = nil
        report = nil
    }

    func reload() async {
        let service = service
        do {
            board = try await Task.detached { try service.board() }.value
            let known = Set((board?.groups ?? []).flatMap { $0.events.map(\.id) })
            selections = selections.filter { known.contains($0.key) }
        } catch {
            notice = "Conflicts could not be loaded. Try again."
        }
    }

    func reviewChanges() async {
        guard busy == nil else { return }
        let replies = pendingReplies
        let service = service
        busy = "Checking…"
        notice = nil
        do {
            preview = try await Task.detached { try service.preview(replies) }.value
        } catch {
            notice = "That combination can't be applied. Change a choice and try again."
        }
        busy = nil
    }

    func backToChoices() {
        preview = nil
    }

    func send() async {
        guard busy == nil else { return }
        let replies = pendingReplies
        let service = service
        busy = "Sending replies…"
        notice = nil
        do {
            report = try await Task.detached { try await service.apply(replies) }.value
            preview = nil
            selections = [:]
        } catch {
            notice = "Nothing was sent. Choose at least one reply and try again."
        }
        busy = nil
        await reload()
    }

    func dismissReport() {
        report = nil
    }
}
