import Foundation
import Security

@main struct NASAdapterIntegration {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "adapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = "nas-adapter-fixture-" + UUID().uuidString
        let privacy = FolderPrivacyStore(service: service)
        let unlocked = await privacy.unlock(pin: "1234", confirmation: "1234")
        precondition(unlocked == nil)
        defer { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary) }
        let connection = NASConnection(name: "Synthetic SMB", kind: .smb, host: "nas.example.test", username: "fixture-user")
        try NASCredentialStore.save(password: "fixture-password", for: connection.id)
        defer { try? NASCredentialStore.delete(for: connection.id) }
        var share = connection; share.share = "videos"
        try privacy.setHidden(location: FolderPrivacyStore.networkLocation(share, path: "/Private"), name: "hidden NAS", hidden: true)
        try privacy.setHidden(location: FolderPrivacyLocation(scope: "file", path: "/synthetic-local"), name: "local secret", hidden: true)
        let recent = NASRecentStore(storageURL: root.appending(path: "history.json"))
        let entry = NASEntry(path: "/Private/movie.mkv", name: "movie.mkv", isDirectory: false, size: 100, modifiedAt: nil)
        precondition(recent.record(connectionID: connection.id, entry: entry, position: 12.5, duration: 100, share: "videos"))
        precondition(recent.record(connectionID: connection.id, entry: entry, position: 50, duration: 100, share: "different-share"))
        let values = try NASCloudAdapter.snapshot(connections: [connection], recents: recent, privacy: privacy)
        precondition(values.count == 4)
        let encoded = try JSONEncoder().encode(values)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("synthetic-local"))
        let (servers, videos, rules) = try NASCloudAdapter.decode(values)
        precondition(servers.count == 1 && servers[0].1 == "fixture-password" && servers[0].0.share.isEmpty)
        precondition(Set(videos.compactMap(\.share)) == ["videos", "different-share"])
        try recent.replaceFromAccount(videos)
        precondition(recent.resumePosition(connectionID: connection.id, entry: entry, share: "videos") == 12.5)
        precondition(recent.resumePosition(connectionID: connection.id, entry: entry, share: "different-share") == 50)
        let freshService = "nas-adapter-fresh-" + UUID().uuidString
        defer { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: freshService] as CFDictionary) }
        let fresh = FolderPrivacyStore(service: freshService)
        try fresh.replaceNetworkRules(rules)
        precondition(!fresh.hasPIN && !fresh.visible(FolderPrivacyStore.networkLocation(share, path: entry.path)))
        let restored = FolderPrivacyStore(service: freshService)
        precondition(restored.errorMessage == nil && !restored.visible(FolderPrivacyStore.networkLocation(share, path: entry.path)))
        try privacy.replaceNetworkRules([])
        precondition(privacy.hiddenFolders.count == 1 && privacy.hiddenFolders[0].location.scope == "file")
        print("PASS Swift adapters: Keychain password, SMB multi-share resume, private folders remain hidden before PIN creation, local rules excluded and preserved")
    }
}
