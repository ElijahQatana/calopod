import CalopodDomain
import Foundation

public enum SyncFixtures {
    public static let start = Date(timeIntervalSince1970: 1_735_689_600)
    public static let end = Date(timeIntervalSince1970: 1_735_776_000)

    public static func oneDayWindow() throws -> SyncWindow {
        try SyncWindow(start: start, end: end)
    }
}
