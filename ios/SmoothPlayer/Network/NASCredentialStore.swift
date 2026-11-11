import Foundation
import Security

enum NASCredentialStore {
    #if SMOOTH_HACKATHON_DEMO
    private static let service = "com.nodelabs.smoothplayer.mac.paypal-demo.nas"
    #else
    private static let service = "com.nodelabs.smoothplayer.nas"
    #endif
    private final class Aliases: @unchecked Sendable {
        let lock = NSLock()
        var values: [UUID: UUID] = [:]
    }
    private static let aliases = Aliases()
    static func resolvedConnectionID(_ id: UUID) -> UUID {
        aliases.lock.lock(); defer { aliases.lock.unlock() }
        return aliases.values[id] ?? id
    }
    static var connectionAliases: [UUID: UUID] {
        aliases.lock.lock(); defer { aliases.lock.unlock() }; return aliases.values
    }
    static func registerAliases(_ next: [UUID: UUID], validConnectionIDs: Set<UUID>) {
        aliases.lock.lock(); defer { aliases.lock.unlock() }
        var values = aliases.values.merging(next) { _, new in new }
        for (old, target) in values { values[old] = next[target] ?? target }
        aliases.values = values.filter { !validConnectionIDs.contains($0.key) && validConnectionIDs.contains($0.value) }
    }

    private static func query(for id: UUID? = nil) -> [CFString: Any] {
        var result: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrSynchronizable: false]
        if let id { result[kSecAttrAccount] = id.uuidString }
        return result
    }

    static func save(password: String, for id: UUID) throws {
        guard let data = password.data(using: .utf8), !password.contains("\0") else { throw NASError.credentialStorage }
        let match = query(for: id)
        let changes: [CFString: Any] = [kSecValueData: data,
                                        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(match as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(match.merging(changes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NASError.credentialStorage }
    }

    static func password(for id: UUID) throws -> String {
        var match = query(for: resolvedConnectionID(id))
        match[kSecReturnData] = true
        match[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(match as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { throw NASError.credentialStorage }
        return value
    }

    static func delete(for id: UUID) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NASError.credentialStorage }
    }

    /// Deletes only this app's NAS passwords; unrelated credentials and purchase records are untouched.
    static func deleteAll() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NASError.credentialStorage }
    }
}
