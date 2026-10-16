/// Calendar colors from providers arrive in different shapes. Only a plain `#rrggbb` is kept.
public enum ProviderColor {
    public static func hex(_ raw: String?) -> String? {
        guard let raw, raw.count == 7, raw.hasPrefix("#") else { return nil }
        let digits = raw.dropFirst().lowercased()
        return digits.allSatisfy(\.isHexDigit) ? "#" + digits : nil
    }

    public static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        let packed = byte(red) << 16 | byte(green) << 8 | byte(blue)
        let digits = String(packed, radix: 16)
        return "#" + String(repeating: "0", count: 6 - digits.count) + digits
    }
}
