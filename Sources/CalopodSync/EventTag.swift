import CalopodStore
import Foundation

enum EventTag: String, CaseIterable {
    case dontClone = "dontclone"
    case justBusy = "justbusy"

    private static let tagCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "#_-"))

    /// The tags in the notes, or in the title when the notes have none.
    static func read(_ event: StoredNormalizedInstance) -> Set<EventTag> {
        for text in [event.notes, event.title] {
            let found = tags(in: text)
            if !found.isEmpty { return found }
        }
        return []
    }

    private static func tags(in text: String?) -> Set<EventTag> {
        guard let text else { return [] }
        let words = Set(text.lowercased().components(separatedBy: tagCharacters.inverted))
        return Set(allCases.filter { words.contains("#" + $0.rawValue) })
    }
}
