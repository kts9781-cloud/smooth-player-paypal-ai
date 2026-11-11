import Foundation
import Security

// Standalone coordinator harness. Only unrelated NAS thumbnail recovery is stubbed;
// account HTTP, signed login, encrypted vault and sync coordinator are production code.
func SPText(_ text: String) -> String { text }
func SPServerText(_ text: String) -> String { text }
enum NASError: Error { case credentialStorage, limitExceeded }
enum NASPreviewIdentity {
    static func migrations(from: [String: NASCloudValue], to: [String: NASCloudValue]) -> [String: String] { [:] }
}
@MainActor final class NASVideoThumbnails {
    static let shared = NASVideoThumbnails()
    func preserveCachedPreviews(_ values: [String: String]) {}
}

@main struct YouTubeSyncIntegration {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let configuration = AccountConfiguration(origin: URL(string: "http://127.0.0.1:8874")!,
            publicKey: try String(contentsOf: root.appending(path: "public-key.txt"), encoding: .utf8), environment: "test")
        let service = "com.nodelabs.smoothplayer.youtube-fixture." + UUID().uuidString
        let account = AccountStore(configuration: configuration, service: service)
        func login(_ email: String) async throws {
            await account.requestCode(email: email)
            precondition(account.challengeId != nil)
            let outbox = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "outbox.json"))) as! [String: String]
            await account.signIn(code: outbox["code"]!)
            precondition(account.session != nil)
        }
        try await login("youtube-fixture@example.test")
        let second = AccountStore(configuration: configuration, service: service)
        let namespaces = (0..<3).map { "youtube-http-\($0)-\(UUID())" }
        defer {
            for namespace in namespaces {
                SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "com.nodelabs.smoothplayer.nas-sync",
                    kSecAttrAccount: NASCloudIdentity.uuid(configuration.origin.absoluteString + namespace)] as CFDictionary)
            }
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        }
        let key = NASCloudIdentity.youtube("aDlDyJM5fd8")
        let original = YouTubeCloudRecent(videoID: "aDlDyJM5fd8", title: "Synthetic 한글", position: 37.5, duration: 196, openedAt: 1790000001)
        var a: [String: NASCloudValue] = [key: .youtube(original)]
        var b: [String: NASCloudValue] = [:]
        var legacy: [String: NASCloudValue] = [:]
        let syncA = NASAccountSync(account: account, namespace: namespaces[0], storageRoot: root, includeYouTube: true, snapshot: { a }, apply: { a = $0 })
        let syncB = NASAccountSync(account: second, namespace: namespaces[1], storageRoot: root, includeYouTube: true, snapshot: { b }, apply: { b = $0 })
        let old = NASAccountSync(account: second, namespace: namespaces[2], storageRoot: root, snapshot: { legacy }, apply: { legacy = $0 })
        account.nasSync = syncA; second.nasSync = syncB
        await syncA.synchronize(); await syncB.synchronize()
        precondition(b == a && b[key] == .youtube(original), "Two-device upload/download failed")
        await old.synchronize(); precondition(legacy.isEmpty, "Legacy client saw unsupported YouTube")
        var latest = original; latest.position = 0; latest.openedAt += 20
        a[key] = .youtube(latest); await syncA.synchronize()
        var stale = original; stale.position = 60; stale.openedAt += 10
        b[key] = .youtube(stale); await syncB.synchronize()
        precondition(b[key] == .youtube(latest), "Stale watch overwrote completion")
        a.removeValue(forKey: key); await syncA.synchronize(); await syncB.synchronize()
        precondition(b.isEmpty, "Deletion did not propagate")
        a[key] = .youtube(latest); await syncA.synchronize()
        let reloaded = NASAccountSync(account: account, namespace: namespaces[0], storageRoot: root, includeYouTube: true, snapshot: { a }, apply: { a = $0 })
        account.nasSync = reloaded; await reloaded.synchronize()
        precondition(a[key] == .youtube(latest), "Encrypted baseline reload failed")
        await account.signOut(); precondition(a.isEmpty, "Logout retained account history")
        try await login("another-youtube-fixture@example.test")
        await reloaded.synchronize(); precondition(a.isEmpty, "History leaked between accounts")
        await account.deleteAccount()
        print("PASS YouTube HTTP: upload/download, old-client coexistence, completion/stale watch, deletion, encrypted reload, logout/account isolation")
    }
}
