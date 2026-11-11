import Foundation
import CryptoKit

struct AccountLicenseEnvelope: Codable, Equatable, Sendable {
    let payload: String
    let signature: String
}

struct AccountLicense: Codable, Sendable {
    let version: Int
    let issuer: String
    let environment: String
    let subject: String
    let issuedAt: Double
    let expiresAt: Double
    let products: [String]

    static func verified(_ envelope: AccountLicenseEnvelope, publicKey: String, issuer: String,
                         environment: String, subject: String, now: Date = Date()) -> AccountLicense? {
        guard let bytes = Data(base64Encoded: envelope.payload), bytes.count <= 8192,
              let signatureData = Data(base64Encoded: envelope.signature),
              let keyData = Data(base64Encoded: publicKey),
              let key = try? P256.Signing.PublicKey(derRepresentation: keyData),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              key.isValidSignature(signature, for: bytes),
              let value = try? JSONDecoder().decode(AccountLicense.self, from: bytes),
              value.version == 1, value.issuer == issuer, value.environment == environment,
              value.subject == subject, UUID(uuidString: subject) != nil,
              value.issuedAt.isFinite, value.expiresAt.isFinite,
              value.issuedAt <= now.timeIntervalSince1970 + 60,
              value.expiresAt > now.timeIntervalSince1970,
              value.expiresAt > value.issuedAt, value.expiresAt - value.issuedAt <= 7 * 86400,
              Set(value.products).isSubset(of: ["smooth_monthly", "smooth_lifetime"]) else { return nil }
        return value
    }
}
