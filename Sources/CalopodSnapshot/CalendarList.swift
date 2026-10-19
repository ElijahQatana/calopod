import Foundation

/// A calendar's name and the color chosen for it on the Mac, as a position in the 12-color palette.
public struct CalendarEntry: Codable, Equatable, Sendable {
    public static let paletteSize = 12

    public let id: String
    public let name: String
    public let colorIndex: Int

    public init(id: String, name: String, colorIndex: Int) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let index = try container.decode(Int.self, forKey: .colorIndex)
        guard (0..<Self.paletteSize).contains(index) else {
            throw DecodingError.dataCorruptedError(
                forKey: .colorIndex, in: container, debugDescription: "Color index \(index) is outside the palette.")
        }
        colorIndex = index
    }

    private enum CodingKeys: String, CodingKey { case id, name, colorIndex }
}

public struct CalendarList: SnapshotRecord {
    public static let recordID = "calendars"

    public let calendars: [CalendarEntry]

    public var id: String { Self.recordID }

    public init(calendars: [CalendarEntry]) {
        self.calendars = calendars
    }

    private enum CodingKeys: String, CodingKey { case calendars }
}
