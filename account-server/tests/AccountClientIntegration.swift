import Foundation

@main
struct Integration {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let key = try String(contentsOf: directory.appendingPathComponent("public-key.txt"), encoding: .utf8)
        let config = AccountConfiguration(origin: URL(string: "http://127.0.0.1:8874")!, publicKey: key, environment: "test")
        let service = "com.nodelabs.smoothplayer.account-integration." + UUID().uuidString
        let store = AccountStore(configuration: config, service: service)
        await store.requestCode(email: "native@example.test")
        guard store.challengeId != nil else { fatalError(store.message ?? "No challenge") }
        let outbox = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("outbox.json"))) as! [String: String]
        await store.signIn(code: outbox["code"]!)
        guard store.session != nil, !store.hasPaidAccess else { fatalError("Login failed") }
        await store.redeemComplimentary(code: "invalid-fixture")
        guard !store.hasPaidAccess else { fatalError("Invalid code unlocked access") }
        await store.redeemComplimentary(code: "fixture-free-code")
        guard store.hasPaidAccess else { fatalError(store.message ?? "Complimentary grant failed") }
        let freeRestored = AccountStore(configuration: config, service: service)
        guard freeRestored.hasPaidAccess else { fatalError("Complimentary Keychain restore failed") }
        await store.redeemComplimentary(code: "fixture-free-code")
        guard store.hasPaidAccess else { fatalError("Repeated code lost access") }
        try await store.linkApple(signedTransaction: "fixture-receipt")
        guard store.hasPaidAccess else { fatalError("Grant not applied") }
        let restored = AccountStore(configuration: config, service: service)
        guard restored.hasPaidAccess, restored.session?.userId == store.session?.userId else { fatalError("Keychain restore failed") }
        await store.signOut()
        guard !store.hasPaidAccess, store.session == nil else { fatalError("Logout retained grant") }
        let signedOut = AccountStore(configuration: config, service: service)
        guard !signedOut.hasPaidAccess, signedOut.session == nil else { fatalError("Persisted logout failed") }
        print("PASS: real HTTP email login, incorrect/valid/repeated complimentary code, purchase link, P-256 verification, Keychain reload, logout (fixture provider only)")
    }
}
