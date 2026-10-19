/// The twelve colors a calendar can be given. The Mac app, the command line and the iPhone app all
/// draw from this one list. Dark values are lifted to hold up on dark surfaces.
public struct CalendarPaletteEntry: Equatable, Sendable {
    public let id: String
    public let name: String
    public let light: UInt32
    public let dark: UInt32

    public init(id: String, name: String, light: UInt32, dark: UInt32) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
    }
}

public enum CalendarPalette {
    public static let entries: [CalendarPaletteEntry] = [
        CalendarPaletteEntry(id: "blue", name: "Blue", light: 0x3a5fcd, dark: 0x7b9af0),
        CalendarPaletteEntry(id: "orange", name: "Orange", light: 0xd9731a, dark: 0xf2a04a),
        CalendarPaletteEntry(id: "green", name: "Green", light: 0x2f9e5f, dark: 0x5cc88b),
        CalendarPaletteEntry(id: "purple", name: "Purple", light: 0x9a4fc0, dark: 0xc58be8),
        CalendarPaletteEntry(id: "red", name: "Red", light: 0xc8453b, dark: 0xef7b6f),
        CalendarPaletteEntry(id: "teal", name: "Teal", light: 0x12908e, dark: 0x4cc3c0),
        CalendarPaletteEntry(id: "pink", name: "Pink", light: 0xcc4a8f, dark: 0xef82bb),
        CalendarPaletteEntry(id: "amber", name: "Amber", light: 0xb8860b, dark: 0xe5b83a),
        CalendarPaletteEntry(id: "sky", name: "Sky", light: 0x1f8ac4, dark: 0x5db4ec),
        CalendarPaletteEntry(id: "lime", name: "Lime", light: 0x6f9a1f, dark: 0xa3c94f),
        CalendarPaletteEntry(id: "indigo", name: "Indigo", light: 0x5b4bc4, dark: 0x9a8cf0),
        CalendarPaletteEntry(id: "gray", name: "Gray", light: 0x6b7280, dark: 0xa1a8b3),
    ]

    /// The color for a calendar with no choice, or one that can't be found.
    public static let neutral = entries[entries.count - 1]

    public static func entry(id: String) -> CalendarPaletteEntry? { entries.first { $0.id == id } }

    /// The color a feed entry means. The id wins; the position is only for a feed from a Mac that
    /// sent no id. A missing or unknown value gives the neutral color.
    public static func entry(id: String?, position: Int?) -> CalendarPaletteEntry {
        if let id { return entry(id: id) ?? neutral }
        guard let position, entries.indices.contains(position) else { return neutral }
        return entries[position]
    }
}
