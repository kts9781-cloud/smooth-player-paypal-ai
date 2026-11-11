import Foundation
import CryptoKit

/// Reserves an unbound receipt for the first signed-in account, including failed network retries.
struct PurchaseLinkOwner {
    var read: (String) -> String?
    var write: (String, String) -> Bool

    func owner(scope: String, receipt: String, storeOwner: UUID?, signedIn: UUID) -> UUID? {
        if let storeOwner { return storeOwner }
        let key = SHA256.hash(data: Data("\(scope)\n\(receipt)".utf8)).map { String(format: "%02x", $0) }.joined()
        if let saved = read(key) { return UUID(uuidString: saved) }
        return write(key, signedIn.uuidString) ? signedIn : nil
    }
}
