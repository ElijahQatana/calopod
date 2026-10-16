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
    private(set) var result: InboxReplyResult?
    var selection: String? {
        didSet { if selection != oldValue { result = nil; Task { await loadDetail() } } }
    }

    let review = InboxReviewModel()
    private let service: InboxScreenService
    private var loads = 0

    init(service: InboxScreenService = InboxScreenService()) {
        self.service = service
    }

    var isBusy: Bool { busy != nil }
    /// What the sidebar badge shows: everything that needs attention.
    var count: Int { board?.entries.count ?? 0 }

    func reload() async {
        let service = service
        loads += 1
        let load = loads
        do {
            let loaded = try await Task.detached { try service.board() }.value
            // Several screens reload at once; an older read must not replace a newer one.
            if load == loads { board = loaded }
        } catch {
            notice = "The inbox could not be loaded. Try again."
        }
        if let selection, board?.entries.contains(where: { $0.id == selection }) != true { self.selection = nil }
        await loadDetail()
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

    func reply(_ choice: ConflictChoice) async {
        guard busy == nil, let id = selection else { return }
        let service = service
        busy = "Sending your reply…"
        notice = nil
        let outcome = await Task.detached { await service.reply(to: id, choice) }.value
        busy = nil
        await reload()
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

    /// Moves on without replying or changing anything.
    func hold(in entries: [InboxEntry]) {
        guard let index = entries.firstIndex(where: { $0.id == selection }) else { return }
        let next = entries.indices.contains(index + 1) ? index + 1 : 0
        selection = entries[next].id
    }

    private func loadDetail() async {
        guard let id = selection else { detail = nil; return }
        let service = service
        let loaded = try? await Task.detached { try service.detail(for: id) }.value
        if selection == id { detail = loaded }
    }
}
