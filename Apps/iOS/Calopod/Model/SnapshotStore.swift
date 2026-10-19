import Foundation
import Observation

@MainActor
@Observable
final class SnapshotStore {
    enum Phase: Equatable {
        case loading
        case sharingOff
        case nothingPublished
        /// `offline` is true when the last refresh failed and this is the cached copy.
        case content(Snapshot, offline: Bool)
        case failed
        case needsNewerApp
        case signedOut
    }

    private(set) var phase: Phase = .loading

    private let reader: SnapshotReader
    private let cache: SnapshotCache

    init(reader: SnapshotReader, cache: SnapshotCache) {
        self.reader = reader
        self.cache = cache
        if let cached = cache.load() { phase = .content(cached, offline: false) }
    }

    func refresh() async {
        do {
            switch try await reader.read() {
            case .sharingOff:
                cache.clear()
                phase = .sharingOff
            case .nothingPublished:
                cache.clear()
                phase = .nothingPublished
            case .snapshot(let snapshot):
                cache.save(snapshot)
                phase = .content(snapshot, offline: false)
            }
        } catch ReaderError.needsNewerApp {
            phase = .needsNewerApp
        } catch ReaderError.signedOut {
            if case .content(let snapshot, _) = phase { phase = .content(snapshot, offline: true) } else { phase = .signedOut }
        } catch {
            if case .content(let snapshot, _) = phase {
                phase = .content(snapshot, offline: true)
            } else {
                phase = .failed
            }
        }
    }
}
