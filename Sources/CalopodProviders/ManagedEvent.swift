import CalopodDomain
import CalopodStore
import CryptoKit
import Foundation

public struct ManagedEventProvenance: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let configurationID: String
    public let armID: String
    public let mirrorKey: String
    public let sourceKeyHash: String
    public let ruleMode: ArmRuleMode
    public let ownershipKeyID: String
    public let authenticationTag: String

    public init(
        schemaVersion: Int = 1,
        configurationID: String,
        armID: String,
        mirrorKey: String,
        sourceKeyHash: String,
        ruleMode: ArmRuleMode,
        ownershipKeyID: String,
        authenticationTag: String
    ) {
        self.schemaVersion = schemaVersion
        self.configurationID = configurationID
        self.armID = armID
        self.mirrorKey = mirrorKey
        self.sourceKeyHash = sourceKeyHash
        self.ruleMode = ruleMode
        self.ownershipKeyID = ownershipKeyID
        self.authenticationTag = authenticationTag
    }
}

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

public struct ManagedEventWriteResult: Codable, Equatable, Sendable {
    public let providerEventID: String
    public let providerVersion: String?

    public init(providerEventID: String, providerVersion: String?) {
        self.providerEventID = providerEventID
        self.providerVersion = providerVersion
    }
}

public enum ManagedEventMarkerStatus: String, Codable, Equatable, Sendable {
    case absent
    case invalid
    case parsed
}

public struct ManagedEventSnapshot: Codable, Equatable, Sendable {
    public let providerEventID: String
    public let providerVersion: String?
    public let payload: DesiredEventPayload?
    public let markerStatus: ManagedEventMarkerStatus
    public let provenance: ManagedEventProvenance?

    public init(
        providerEventID: String,
        providerVersion: String?,
        payload: DesiredEventPayload?,
        markerStatus: ManagedEventMarkerStatus,
        provenance: ManagedEventProvenance?
    ) {
        self.providerEventID = providerEventID
        self.providerVersion = providerVersion
        self.payload = payload
        self.markerStatus = markerStatus
        self.provenance = provenance
    }
}

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

public enum OwnershipMarkerCodec {
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

    public static func sign(
        configurationID: String,
        armID: String,
        mirrorKey: String,
        sourceKeyHash: String,
        ruleMode: ArmRuleMode,
        key: OwnershipKeyMaterial
    ) throws -> ManagedEventProvenance {
        guard key.bytes.count >= 32 else { throw OwnershipMarkerError.invalidKey }
        let fields = canonicalFields(
            schemaVersion: 1,
            configurationID: configurationID,
            armID: armID,
            mirrorKey: mirrorKey,
            sourceKeyHash: sourceKeyHash,
            ruleMode: ruleMode,
            ownershipKeyID: key.id
        )
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(fields.utf8),
            using: SymmetricKey(data: key.bytes)
        )
        return ManagedEventProvenance(
            configurationID: configurationID,
            armID: armID,
            mirrorKey: mirrorKey,
            sourceKeyHash: sourceKeyHash,
            ruleMode: ruleMode,
            ownershipKeyID: key.id,
            authenticationTag: base64URL(Data(authentication))
        )
    }

    public static func verify(
        _ marker: ManagedEventProvenance,
        key: OwnershipKeyMaterial
    ) throws {
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
            ownershipKeyID: marker.ownershipKeyID
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(
            supplied,
            authenticating: Data(fields.utf8),
            using: SymmetricKey(data: key.bytes)
        ) else {
            throw OwnershipMarkerError.signatureMismatch
        }
    }

    public static func markerURL(_ marker: ManagedEventProvenance) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = base64URL(try encoder.encode(CompactOwnershipMarker(marker)))
        guard let url = URL(string: "calopod://managed/v1/\(encoded)") else {
            throw OwnershipMarkerError.invalidMarker
        }
        return url
    }

    public static func marker(from url: URL) throws -> ManagedEventProvenance {
        guard url.scheme == "calopod", url.host == "managed",
              url.pathComponents.count == 3, url.pathComponents[1] == "v1",
              let data = dataFromBase64URL(url.pathComponents[2]),
              let compact = try? JSONDecoder().decode(CompactOwnershipMarker.self, from: data) else {
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
        ownershipKeyID: String
    ) -> String {
        [
            String(schemaVersion),
            configurationID,
            armID,
            mirrorKey,
            sourceKeyHash,
            ruleMode.rawValue,
            ownershipKeyID,
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
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

    init(_ marker: ManagedEventProvenance) {
        v = marker.schemaVersion
        c = marker.configurationID
        a = marker.armID
        m = marker.mirrorKey
        s = marker.sourceKeyHash
        r = marker.ruleMode
        k = marker.ownershipKeyID
        t = marker.authenticationTag
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
            authenticationTag: t
        )
    }
}
