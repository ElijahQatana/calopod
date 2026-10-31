import CalopodDomain
import CalopodStore

/// Where Calopod puts a copy of one source event, read from the enabled arms' mappings.
/// The app and the command line both draw copies from this, so they agree.
struct CopyTarget: Equatable {
    let bindingID: String
    let armName: String
    let fullDetails: Bool
    let arm: StoredArm

    /// Copy targets by source event key. Read once per schedule or listing.
    static func bySource(_ repository: LocalStateRepository, arms: [StoredArm]) throws -> [String: [CopyTarget]] {
        var found: [String: [CopyTarget]] = [:]
        for arm in arms where arm.isEnabled {
            for mapping in try repository.mirrorMappings(armID: arm.id) {
                found[mapping.sourceKeyHash, default: []].append(
                    CopyTarget(bindingID: arm.targetBindingID, armName: arm.displayName, fullDetails: arm.ruleMode == .fullDetails, arm: arm))
            }
        }
        return found
    }

    /// Mode word used in JSON.
    var modeName: String { fullDetails ? "full-details" : "busy" }
}

/// The answer on a source event as the command line prints it.
func copyResponseName(_ state: EventResponseState) -> String? {
    switch state {
    case .accepted: "accepted"
    case .tentative: "tentative"
    case .declined: "declined"
    case .needsResponse: "needs-response"
    case .organizer: "organizer"
    case .notApplicable, .unknown: nil
    }
}
