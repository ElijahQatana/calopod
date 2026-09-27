import CalopodDomain
import Foundation

/// Best-effort guess at which hosted provider an EventKit calendar's source
/// actually belongs to (macOS exposes Exchange/Google/iCloud accounts as
/// EventKit sources with only loosely structured type/label metadata). Used
/// to warn against adding the same account twice — once through EventKit
/// and once through a direct Google/Microsoft connection — never to make
/// sync decisions on its own.
public enum EventKitSourceClassifier {
    public static func likelyDirectProvider(
        sourceType: String?,
        sourceLabel: String?
    ) -> ProviderKind? {
        let type = sourceType?.lowercased()
        let label = sourceLabel?.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased() ?? ""

        if type == "exchange" || containsMicrosoftMarker(label) {
            return .microsoft
        }
        if containsGoogleMarker(label) {
            return .google
        }
        return nil
    }

    private static func containsGoogleMarker(_ label: String) -> Bool {
        ["google", "gmail", "googlemail"].contains { label.contains($0) }
    }

    private static func containsMicrosoftMarker(_ label: String) -> Bool {
        ["microsoft", "office 365", "outlook", "hotmail", "live.com", "exchange"]
            .contains { label.contains($0) }
    }
}
