import CalopodDomain
import Foundation

/// Best-effort guess at which provider an EventKit source belongs to, from loose type and label
/// metadata. Only used to warn about duplicate accounts.
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
