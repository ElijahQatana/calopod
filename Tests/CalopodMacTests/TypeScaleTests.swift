import Foundation
import XCTest

/// Screens take their text sizes from Theme.Fonts, so a raw size or text style outside
/// Design.swift is a slip.
final class TypeScaleTests: XCTestCase {
    func testNoRawFontSizesOutsideDesign() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CalopodMac")
        let raw = try NSRegularExpression(
            pattern: #"\.font\(\s*(\.system\(size:|\.(callout|caption2?|headline|subheadline|footnote|title[23]?|largeTitle|body)\b)"#)
        var offenders: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" && file.lastPathComponent != "Design.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if raw.firstMatch(in: line, range: range) != nil { offenders.append("\(file.lastPathComponent):\(number + 1)") }
            }
        }
        XCTAssertEqual(offenders, [], "Use Theme.Fonts instead of raw sizes")
    }
}
