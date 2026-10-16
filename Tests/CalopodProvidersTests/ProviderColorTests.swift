@testable import CalopodProviders
import Testing

@Test(arguments: [
    ("#1A8CFF", "#1a8cff"), ("#000000", "#000000"),
    ("", nil), ("auto", nil), ("1A8CFF", nil), ("#fff", nil), ("#12345g", nil), (nil, nil),
] as [(String?, String?)])
func providerColorIsKeptOnlyAsPlainHex(raw: String?, expected: String?) {
    #expect(ProviderColor.hex(raw) == expected)
}

@Test
func providerColorFromComponents() {
    #expect(ProviderColor.hex(red: 1, green: 0.5, blue: 0) == "#ff8000")
    #expect(ProviderColor.hex(red: 0, green: 0, blue: 0.02) == "#000005")
    #expect(ProviderColor.hex(red: 2, green: -1, blue: 0) == "#ff0000")
}
