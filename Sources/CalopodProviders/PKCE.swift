import CryptoKit
import Foundation

public struct PKCEPair: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }

    public static func generate() -> PKCEPair {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        let verifier = String((0..<64).map { _ in characters.randomElement(using: &generator)! })
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return PKCEPair(verifier: verifier, challenge: challenge)
    }
}

public func formEncoded(_ values: [String: String]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let body: String = values.keys.sorted().map { key in
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let value = values[key] ?? ""
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")
    return Data(body.utf8)
}
