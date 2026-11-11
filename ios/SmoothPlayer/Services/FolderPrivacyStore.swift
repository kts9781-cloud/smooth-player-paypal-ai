import Foundation
import Observation
import Security
import CommonCrypto
import SwiftUI

struct HiddenFolderRule: Identifiable, Codable {
    var id = UUID()
    let location: FolderPrivacyLocation
    let name: String
    var bookmark: Data?
}
struct SavedLocalFolder: Identifiable, Codable {
    var id = UUID()
    let name: String
    let bookmark: Data
}

@MainActor @Observable
final class FolderPrivacyStore {
    private struct Config: Codable {
        var salt = Data()
        var hash = Data()
        var failures = 0
        var lockedUntil = Date.distantPast
        var rules: [HiddenFolderRule] = []
        var local: [SavedLocalFolder] = []
    }
    private var config = Config()
    private(set) var unlocked = false
    private(set) var errorMessage: String?
    private var generation = 0
    private var authenticating = false
    private let service: String
    private let account = "folder-privacy-v1"
    #if DEBUG || SMOOTH_TEST_HOST
    @ObservationIgnored var onBookmarkResolutionForTesting: (() -> Void)?
    #endif
    var hasPIN: Bool { !config.hash.isEmpty || errorMessage != nil }
    var localFolders: [SavedLocalFolder] { config.local }
    var hiddenFolders: [HiddenFolderRule] { config.rules }

    init(service: String = "com.nodelabs.smoothplayer.folder-privacy") {
        self.service = service
        var query = keyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return }
        do {
            guard status == errSecSuccess, let data = result as? Data else { throw PrivacyError.storage }
            config = try JSONDecoder().decode(Config.self, from: data)
            guard (config.salt.isEmpty && config.hash.isEmpty && config.rules.allSatisfy { $0.location.scope.hasPrefix("ftp://") || $0.location.scope.hasPrefix("smb://") }) || (config.salt.count == 16 && config.hash.count == 32) else { throw PrivacyError.storage }
        } catch { errorMessage = SPText("폴더 잠금 정보를 읽지 못했습니다. 보호된 목록을 열 수 없습니다.") }
    }
    private var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private func save(_ next: Config) throws {
        let data = try JSONEncoder().encode(next)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(keyQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(keyQuery.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw PrivacyError.storage }
        config = next
    }
    func lock() { generation += 1; unlocked = false }
    func replaceNetworkRules(_ rules: [HiddenFolderRule]) throws {
        guard errorMessage == nil, rules.allSatisfy({ $0.bookmark == nil && ($0.location.scope.hasPrefix("ftp://") || $0.location.scope.hasPrefix("smb://")) }) else { throw PrivacyError.storage }
        var next = config
        next.rules = config.rules.filter { !$0.location.scope.hasPrefix("ftp://") && !$0.location.scope.hasPrefix("smb://") } + rules
        if !config.rules.map(\.location).elementsEqual(next.rules.map(\.location)) { lock() }
        try save(next)
    }
    static func validPIN(_ pin: String) -> Bool { pin.utf8.count == 4 && pin.utf8.allSatisfy { (48...57).contains($0) } }
    private nonisolated static func derive(_ pin: String, salt: Data) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = pin.withCString { password in
            salt.withUnsafeBytes { buffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, pin.utf8.count,
                    buffer.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 120_000, &bytes, bytes.count)
            }
        }
        guard status == kCCSuccess else { throw PrivacyError.storage }
        return Data(bytes)
    }
    func unlock(pin: String, confirmation: String) async -> String? {
        guard !authenticating else { return SPText("암호를 확인하고 있습니다.") }
        authenticating = true
        defer { authenticating = false }
        guard errorMessage == nil else { return errorMessage }
        guard Self.validPIN(pin) else { return SPText("숫자 4자리를 입력해 주세요.") }
        guard config.lockedUntil <= .now else { return SPText("입력 횟수를 초과했습니다. 30초 후 다시 시도해 주세요.") }
        let creating = !hasPIN
        guard !creating || pin == confirmation else { return SPText("두 암호가 일치하지 않습니다.") }
        let epoch = generation
        do {
            var next = config
            if creating {
                var bytes = [UInt8](repeating: 0, count: 16)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PrivacyError.storage }
                next.salt = Data(bytes)
            }
            let salt = next.salt
            let candidate = try await Task.detached(priority: .userInitiated) { try Self.derive(pin, salt: salt) }.value
            guard generation == epoch else { return SPText("잠금이 다시 설정되었습니다. 암호를 다시 입력해 주세요.") }
            let matches = candidate.count == next.hash.count && zip(candidate, next.hash).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
            if !creating && !matches {
                next.failures += 1
                if next.failures >= 5 { next.failures = 0; next.lockedUntil = Date.now.addingTimeInterval(30) }
                try save(next)
                return next.lockedUntil > .now ? SPText("5회 틀렸습니다. 30초 후 다시 시도해 주세요.") : SPText("암호가 일치하지 않습니다.")
            }
            if creating { next.hash = candidate }
            next.failures = 0; next.lockedUntil = .distantPast
            try save(next)
            unlocked = true
            return nil
        } catch { return SPText("암호 정보를 저장하지 못했습니다. 다시 시도해 주세요.") }
    }
    static func networkLocation(_ connection: NASConnection, path: String) -> FolderPrivacyLocation {
        let host = connection.host.contains(":") ? "[\(connection.host.lowercased())]" : connection.host.lowercased()
        let base = "\(connection.kind.rawValue)://\(host):\(connection.port)"
        let full = FolderPrivacyLocation.normalized((connection.kind == .smb ? "/\(connection.share)" : "") + "/" + path)
        return FolderPrivacyLocation(scope: base, path: connection.kind == .smb ? full.lowercased() : full)
    }
    static func localLocation(_ url: URL) -> FolderPrivacyLocation {
        FolderPrivacyLocation(scope: "file", path: FolderPrivacyLocation.normalized(url.standardizedFileURL.resolvingSymlinksInPath().path).lowercased())
    }
    private func resolvedLocation(_ rule: HiddenFolderRule) -> FolderPrivacyLocation? {
        guard let bookmark = rule.bookmark else { return rule.location }
        guard let url = try? resolve(bookmark) else { return nil }
        return Self.localLocation(url)
    }
    func protected(_ location: FolderPrivacyLocation) -> Bool {
        if errorMessage != nil { return true }
        return config.rules.contains { rule in
            // A bookmark always resolves to a local file URL. Checking a NAS
            // item must not resolve every local folder bookmark on MainActor.
            // Keep the fail-closed behavior for unreadable local bookmarks.
            guard rule.bookmark == nil || location.scope == "file" else { return false }
            guard let root = resolvedLocation(rule) else { return location.scope == "file" }
            return root.contains(location)
        }
    }
    func visible(_ location: FolderPrivacyLocation) -> Bool { errorMessage == nil && (unlocked || !protected(location)) }
    func explicitlyHidden(_ location: FolderPrivacyLocation) -> Bool { config.rules.contains { resolvedLocation($0) == location } }
    func setHidden(location: FolderPrivacyLocation, name: String, localURL: URL? = nil, hidden: Bool) throws {
        guard unlocked, errorMessage == nil else { throw PrivacyError.locked }
        var next = config
        next.rules.removeAll { resolvedLocation($0) == location }
        if hidden {
            let bookmark = try localURL?.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            next.rules.append(HiddenFolderRule(location: location, name: name, bookmark: bookmark))
        }
        try save(next)
    }
    @discardableResult func registerLocal(_ url: URL) throws -> SavedLocalFolder {
        guard errorMessage == nil else { throw PrivacyError.storage }
        let folder = SavedLocalFolder(name: url.lastPathComponent,
            bookmark: try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
        var next = config
        next.local.removeAll { (try? resolve($0.bookmark)) == url }
        next.local.append(folder)
        try save(next)
        return folder
    }
    func resolve(_ bookmark: Data) throws -> URL {
        #if DEBUG || SMOOTH_TEST_HOST
        onBookmarkResolutionForTesting?()
        #endif
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, url.isFileURL else { throw PrivacyError.storage }
        return url
    }
    func erase() throws {
        guard !hasPIN || unlocked else { throw PrivacyError.locked }
        let status = SecItemDelete(keyQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PrivacyError.storage }
        lock(); config = Config(); errorMessage = nil
    }
    enum PrivacyError: LocalizedError {
        case locked, storage
        var errorDescription: String? { self == .locked ? SPText("먼저 숨긴 폴더의 암호를 입력해 주세요.") : SPText("폴더 잠금 정보를 저장하거나 읽지 못했습니다.") }
    }
}

private struct FolderPrivacyKey: EnvironmentKey { static let defaultValue: FolderPrivacyStore? = nil }
extension EnvironmentValues {
    var folderPrivacy: FolderPrivacyStore? {
        get { self[FolderPrivacyKey.self] }
        set { self[FolderPrivacyKey.self] = newValue }
    }
}
