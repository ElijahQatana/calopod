import CalopodDomain
import CalopodStore
import CryptoKit
import Foundation

/// The signed ownership marker on every managed event. Verified by `OwnershipMarkerCodec.verify`
/// before anything trusts it.
public struct ManagedEventProvenance: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let configurationID: String
    public let armID: String
    public let mirrorKey: String
    public let sourceKeyHash: String
    public let ruleMode: ArmRuleMode
    public let ownershipKeyID: String
    public let authenticationTag: String
    public let targetBindingID: String?

    public init(
        schemaVersion: Int = 1,
        configurationID: String,
        armID: String,
        mirrorKey: String,
        sourceKeyHash: String,
        ruleMode: ArmRuleMode,
        ownershipKeyID: String,
        authenticationTag: String,
        targetBindingID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.configurationID = configurationID
        self.armID = armID
        self.mirrorKey = mirrorKey
        self.sourceKeyHash = sourceKeyHash
        self.ruleMode = ruleMode
        self.ownershipKeyID = ownershipKeyID
        self.authenticationTag = authenticationTag
        self.targetBindingID = targetBindingID
    }
}

/// What a provider client needs to create or update a managed event: the content and the signed
/// marker.
public struct ManagedEventWriteRequest: Codable, Equatable, Sendable {
    public let desiredFingerprint: String
    public let payload: DesiredEventPayload
    public let provenance: ManagedEventProvenance

    public init(
        desiredFingerprint: String,
        payload: DesiredEventPayload,
        provenance: ManagedEventProvenance
    ) {
        self.desiredFingerprint = desiredFingerprint
        self.payload = payload
        self.provenance = provenance
    }
}

/// What a provider returns after a write: the identity and version to address the event again.
public struct ManagedEventWriteResult: Codable, Equatable, Sendable {
    public let providerEventID: String
    public let providerVersion: String?

    public init(providerEventID: String, providerVersion: String?) {
        self.providerEventID = providerEventID
        self.providerVersion = providerVersion
    }
}

/// Whether a marker could be decoded at all, before any signature check. See
/// `ManagedTargetObserver`.
public enum ManagedEventMarkerStatus: String, Codable, Equatable, Sendable {
    case absent
    case invalid
    case parsed
}

/// A raw read of one event on the target calendar. `ManagedTargetObserver` classifies it.
public struct ManagedEventSnapshot: Codable, Equatable, Sendable {
    public let providerEventID: String
    public let providerVersion: String?
    public let payload: DesiredEventPayload?
    public let markerStatus: ManagedEventMarkerStatus
    public let provenance: ManagedEventProvenance?
    public let createdAt: Date?
    public let isProviderPreferredIdentity: Bool

    public init(
        providerEventID: String,
        providerVersion: String?,
        payload: DesiredEventPayload?,
        markerStatus: ManagedEventMarkerStatus,
        provenance: ManagedEventProvenance?,
        createdAt: Date? = nil,
        isProviderPreferredIdentity: Bool = false
    ) {
        self.providerEventID = providerEventID
        self.providerVersion = providerVersion
        self.payload = payload
        self.markerStatus = markerStatus
        self.provenance = provenance
        self.createdAt = createdAt
        self.isProviderPreferredIdentity = isProviderPreferredIdentity
    }
}

/// The key that signs ownership markers for one configuration. It lives in the Keychain, never
/// SQLite.
public struct OwnershipKeyMaterial: Equatable, Sendable {
    public let id: String
    public let bytes: Data

    public init(id: String, bytes: Data) {
        self.id = id
        self.bytes = bytes
    }
}

public enum OwnershipMarkerError: Error, Equatable, Sendable {
    case invalidKey
    case invalidMarker
    case signatureMismatch
}

/// Encodes, signs (HMAC-SHA256) and verifies ownership markers.
public enum OwnershipMarkerCodec {
    /// Parses a provider's marker fields. `.absent` means no marker; `.invalid` means fields exist
    /// but are incomplete.
    public static func marker(fields: [String: String]?) -> (
        status: ManagedEventMarkerStatus,
        provenance: ManagedEventProvenance?
    ) {
        guard let fields else { return (.absent, nil) }
        let names = [
            "calopodSchema",
            "configurationID",
            "armID",
            "mirrorKey",
            "sourceKeyHash",
            "ruleMode",
            "ownershipKeyID",
            "authenticationTag",
        ]
        guard names.contains(where: { fields[$0] != nil }) else {
            return (.absent, nil)
        }
        guard let schemaValue = fields["calopodSchema"],
              let schemaVersion = Int(schemaValue),
              let configurationID = fields["configurationID"],
              let armID = fields["armID"],
              let mirrorKey = fields["mirrorKey"],
              let sourceKeyHash = fields["sourceKeyHash"],
              let ruleValue = fields["ruleMode"],
              let ruleMode = ArmRuleMode(rawValue: ruleValue),
              let ownershipKeyID = fields["ownershipKeyID"],
              let authenticationTag = fields["authenticationTag"],
              !configurationID.isEmpty,
              !armID.isEmpty,
              !mirrorKey.isEmpty,
              !sourceKeyHash.isEmpty,
              !ownershipKeyID.isEmpty,
              !authenticationTag.isEmpty else {
            return (.invalid, nil)
        }
        return (
            .parsed,
            ManagedEventProvenance(
                schemaVersion: schemaVersion,
                configurationID: configurationID,
                armID: armID,
                mirrorKey: mirrorKey,
                sourceKeyHash: sourceKeyHash,
                ruleMode: ruleMode,
                ownershipKeyID: ownershipKeyID,
                authenticationTag: authenticationTag
            )
        )
    }

    /// Signs a marker over its canonical fields. Anyone can read them; only the key holder can
    /// produce a tag that verifies.
    public static func sign(
        configurationID: String,
        armID: String,
        mirrorKey: String,
        sourceKeyHash: String,
        ruleMode: ArmRuleMode,
        key: OwnershipKeyMaterial,
        targetBindingID: String? = nil
    ) throws -> ManagedEventProvenance {
        guard key.bytes.count >= 32 else { throw OwnershipMarkerError.invalidKey }
        let schemaVersion = targetBindingID == nil ? 1 : 2
        let fields = canonicalFields(
            schemaVersion: schemaVersion,
            configurationID: configurationID,
            armID: armID,
            mirrorKey: mirrorKey,
            sourceKeyHash: sourceKeyHash,
            ruleMode: ruleMode,
            ownershipKeyID: key.id,
            targetBindingID: targetBindingID
        )
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(fields.utf8),
            using: SymmetricKey(data: key.bytes)
        )
        return ManagedEventProvenance(
            schemaVersion: schemaVersion,
            configurationID: configurationID,
            armID: armID,
            mirrorKey: mirrorKey,
            sourceKeyHash: sourceKeyHash,
            ruleMode: ruleMode,
            ownershipKeyID: key.id,
            authenticationTag: base64URL(Data(authentication)),
            targetBindingID: targetBindingID
        )
    }

    /// Recomputes the HMAC and compares it to `authenticationTag`. A marker that decodes but fails
    /// here is untrusted.
    public static func verify(
        _ marker: ManagedEventProvenance,
        key: OwnershipKeyMaterial
    ) throws {
        guard (marker.schemaVersion == 1 && marker.targetBindingID == nil)
                || (marker.schemaVersion == 2 && marker.targetBindingID?.isEmpty == false) else {
            throw OwnershipMarkerError.invalidMarker
        }
        guard marker.ownershipKeyID == key.id, key.bytes.count >= 32,
              let supplied = dataFromBase64URL(marker.authenticationTag) else {
            throw OwnershipMarkerError.invalidMarker
        }
        let fields = canonicalFields(
            schemaVersion: marker.schemaVersion,
            configurationID: marker.configurationID,
            armID: marker.armID,
            mirrorKey: marker.mirrorKey,
            sourceKeyHash: marker.sourceKeyHash,
            ruleMode: marker.ruleMode,
            ownershipKeyID: marker.ownershipKeyID,
            targetBindingID: marker.targetBindingID
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(
            supplied,
            authenticating: Data(fields.utf8),
            using: SymmetricKey(data: key.bytes)
        ) else {
            throw OwnershipMarkerError.signatureMismatch
        }
    }

    /// Encodes a marker as a versioned `calopod://managed/` URL for providers like EventKit that
    /// have a URL field but no custom metadata. A source's own meeting link goes in notes instead.
    public static func markerURL(_ marker: ManagedEventProvenance) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = base64URL(try encoder.encode(CompactOwnershipMarker(marker)))
        guard let url = URL(string: "calopod://managed/v\(marker.schemaVersion)/\(encoded)") else {
            throw OwnershipMarkerError.invalidMarker
        }
        return url
    }

    public static func marker(from url: URL) throws -> ManagedEventProvenance {
        guard url.scheme == "calopod", url.host == "managed",
              url.pathComponents.count == 3, ["v1", "v2"].contains(url.pathComponents[1]),
              let data = dataFromBase64URL(url.pathComponents[2]),
              let compact = try? JSONDecoder().decode(CompactOwnershipMarker.self, from: data) else {
            throw OwnershipMarkerError.invalidMarker
        }
        guard url.pathComponents[1] == "v\(compact.v)" else {
            throw OwnershipMarkerError.invalidMarker
        }
        return compact.marker
    }

    private static func canonicalFields(
        schemaVersion: Int,
        configurationID: String,
        armID: String,
        mirrorKey: String,
        sourceKeyHash: String,
        ruleMode: ArmRuleMode,
        ownershipKeyID: String,
        targetBindingID: String?
    ) -> String {
        var fields = [
            String(schemaVersion),
            configurationID,
            armID,
            mirrorKey,
            sourceKeyHash,
            ruleMode.rawValue,
            ownershipKeyID,
        ]
        if schemaVersion == 2 { fields.append(targetBindingID ?? "") }
        return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func dataFromBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// Keychain storage for a configuration's ownership key. `loadOrCreate` creates it on first write.
public struct OwnershipKeyVault: Sendable {
    private let secretStore: any SecretStore

    public init(secretStore: any SecretStore) {
        self.secretStore = secretStore
    }

    public func load(configurationID: String) throws -> OwnershipKeyMaterial? {
        let reference = SecretReference(account: "ownership.\(configurationID).current")
        guard let stored = try secretStore.value(for: reference) else { return nil }
        guard let envelope = try? JSONDecoder().decode(OwnershipKeyEnvelope.self, from: stored),
              let bytes = Data(base64Encoded: envelope.key), bytes.count >= 32 else {
            throw SecretStoreError.unexpectedValue
        }
        return OwnershipKeyMaterial(id: envelope.id, bytes: bytes)
    }

    public func loadOrCreate(configurationID: String) throws -> OwnershipKeyMaterial {
        if let existing = try load(configurationID: configurationID) { return existing }

        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let material = OwnershipKeyMaterial(id: UUID().uuidString.lowercased(), bytes: bytes)
        let envelope = OwnershipKeyEnvelope(id: material.id, key: bytes.base64EncodedString())
        let reference = SecretReference(account: "ownership.\(configurationID).current")
        try secretStore.save(try JSONEncoder().encode(envelope), for: reference)
        return material
    }
}

private struct OwnershipKeyEnvelope: Codable {
    let id: String
    let key: String
}

private struct CompactOwnershipMarker: Codable {
    let v: Int
    let c: String
    let a: String
    let m: String
    let s: String
    let r: ArmRuleMode
    let k: String
    let t: String
    let b: String?

    init(_ marker: ManagedEventProvenance) {
        v = marker.schemaVersion
        c = marker.configurationID
        a = marker.armID
        m = marker.mirrorKey
        s = marker.sourceKeyHash
        r = marker.ruleMode
        k = marker.ownershipKeyID
        t = marker.authenticationTag
        b = marker.targetBindingID
    }

    var marker: ManagedEventProvenance {
        ManagedEventProvenance(
            schemaVersion: v,
            configurationID: c,
            armID: a,
            mirrorKey: m,
            sourceKeyHash: s,
            ruleMode: r,
            ownershipKeyID: k,
            authenticationTag: t,
            targetBindingID: b
        )
    }
}
