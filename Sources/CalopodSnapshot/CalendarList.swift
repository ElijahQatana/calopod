import CalopodDomain
import Foundation

/// A calendar's name and the color chosen for it on the Mac. `color` is the palette id; `colorIndex` is
/// the same color's position, kept for a phone that reads a feed from before ids were sent.
public struct CalendarEntry: Codable, Equatable, Sendable {
    public static let paletteSize = 12

    public let id: String
    public let name: String
    public let colorIndex: Int
    public let color: String?

    public init(id: String, name: String, colorIndex: Int, color: String? = nil) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.color = color
    }

    public var paletteEntry: CalendarPaletteEntry { CalendarPalette.entry(id: color, position: colorIndex) }

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
        color = try container.decodeIfPresent(String.self, forKey: .color)
    }

    private enum CodingKeys: String, CodingKey { case id, name, colorIndex, color }
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
