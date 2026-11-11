import Foundation
import Security

@main struct NASIntegration {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let config = AccountConfiguration(origin: URL(string: "http://127.0.0.1:8874")!,
            publicKey: try String(contentsOf: root.appending(path: "public-key.txt"), encoding: .utf8), environment: "test")
        let service = "com.nodelabs.smoothplayer.nas-fixture." + UUID().uuidString
        let account = AccountStore(configuration: config, service: service)
        func login(_ store: AccountStore, _ email: String) async throws {
            await store.requestCode(email: email)
            guard store.challengeId != nil else { fatalError("Fixture challenge failed") }
            let box = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "outbox.json"))) as! [String:String]
            await store.signIn(code: box["code"]!)
            guard store.session != nil else { fatalError("Fixture sign-in failed") }
        }
        try await login(account, "nas-fixture@example.test")
        let second = AccountStore(configuration: config, service: service)
        let serverID = UUID().uuidString.lowercased(), key = "server:" + serverID
        let original = NASCloudServer(name: "Synthetic NAS", protocol: "ftp", host: "nas.example.test", port: 21, share: "", rootPath: "/",
            username: "fixture-member", password: "fixture-secret-한글", domain: "", ftpEncoding: "cp949")
        let recent = NASCloudRecent(connectionID: serverID, path: "/movie.mkv", encodedPath: nil, name: "movie.mkv", position: 25.25,
            duration: 100, fileSize: 0, modifiedAt: nil, openedAt: 1790000000)
        let recentKey = NASCloudIdentity.recent(serverID, recent.path)
        var a: [String: NASCloudValue] = [key: .server(original), recentKey: .recent(recent)]
        var b: [String: NASCloudValue] = [:]
        let local = Data("untouched local playlist fixture".utf8)
        let localFile = root.appending(path: "local-playlist.txt"); try local.write(to: localFile)
        let namespaceA = "fixture-A-" + UUID().uuidString, namespaceB = "fixture-B-" + UUID().uuidString
        let syncA = NASAccountSync(account: account, namespace: namespaceA, storageRoot: root, snapshot: { a }, apply: { a = $0 })
        var syncB = NASAccountSync(account: second, namespace: namespaceB, storageRoot: root, snapshot: { b }, apply: { _ in throw NASError.credentialStorage })
        account.nasSync = syncA; second.nasSync = syncB
        await syncA.synchronize(); await syncB.synchronize()
        precondition(!syncB.accessReady, "Failed account transition must hide NAS entries")
        syncB = NASAccountSync(account: second, namespace: namespaceB, storageRoot: root, snapshot: { b }, apply: { b = $0 })
        second.nasSync = syncB
        await syncB.synchronize()
        guard b == a, b[key] == .server(original) else { fatalError("Credential/resume transport failed: \(syncA.message), \(syncB.message)") }
        var edited = original; edited.password = "updated-fixture-password"
        a[key] = .server(edited); await syncA.synchronize()
        var stale = original; stale.name = "offline edit"
        b[key] = .server(stale); await syncB.synchronize()
        guard b[key] == .server(edited), syncB.conflictCount == 1 else { fatalError("Stale edit overwrote newer password") }
        syncB.restoreConflicts(); await syncB.synchronize(); await syncA.synchronize()
        guard a[key] == .server(stale) else { fatalError("Explicit conflict restore failed") }
        a.removeValue(forKey: key); a.removeValue(forKey: recentKey); await syncA.synchronize()
        b[key] = .server(edited); await syncB.synchronize()
        guard b.isEmpty else { fatalError("Deleted server resurrected from stale client") }
        // Recreate with the current tombstone version and verify durable baseline reload.
        a[key] = .server(original); await syncA.synchronize()
        let reloaded = NASAccountSync(account: account, namespace: namespaceA, storageRoot: root, snapshot: { a }, apply: { a = $0 })
        account.nasSync = reloaded; await reloaded.synchronize()
        guard a[key] == .server(original) else { fatalError("Encrypted baseline reload failed") }
        let vaultFile = root.appending(path: "nas-account-sync/" + NASCloudIdentity.uuid(config.origin.absoluteString + namespaceA) + ".bin")
        let vault = try Data(contentsOf: vaultFile)
        guard vault.range(of: Data(original.password.utf8)) == nil else { fatalError("Plaintext credentials persisted") }
        await account.signOut()
        guard a.isEmpty else { fatalError("Logout exposed NAS metadata") }
        try await login(account, "different-nas-fixture@example.test")
        await reloaded.synchronize()
        guard a.isEmpty else { fatalError("Previous account data uploaded to new account") }
        guard try Data(contentsOf: localFile) == local else { fatalError("Local playlist changed") }
        await account.deleteAccount()
        // Remove only the unique synthetic Keychain entries created by this test.
        for ns in [namespaceA, namespaceB] {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "com.nodelabs.smoothplayer.nas-sync",
                kSecAttrAccount: NASCloudIdentity.uuid(config.origin.absoluteString + ns)] as CFDictionary)
        }
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        print("PASS Swift HTTP: password/resume sync, conflict preservation/restore, tombstones, encrypted vault reload, logout/account isolation, local playlist unchanged, interrupted import recovered")
    }
}
