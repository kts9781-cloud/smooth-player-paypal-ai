import Foundation

@main struct SocialClientIntegration {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let key = try String(contentsOf: directory.appendingPathComponent("public-key.txt"), encoding: .utf8)
        let config = AccountConfiguration(origin: URL(string: "http://127.0.0.1:8874")!, publicKey: key, environment: "test")
        let service = "com.nodelabs.smoothplayer.social-fixture." + UUID().uuidString
        let store = AccountStore(configuration: config, service: service)
        func check(_ value: Bool, _ text: String) { if !value { fatalError(text + ": " + (store.message ?? "")) } }
        await store.loadLoginProviders()
        check(store.loginProviders.count == 2 && store.loginProviders.allSatisfy(\.enabled), "Providers")
        let authenticate: (URL) async throws -> URL = { url in
            var request = URLRequest(url: config.origin.appendingPathComponent("fixture/social"))
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["id": url.lastPathComponent])
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode([String: String].self, from: data)
            return URL(string: response["callback"]!)!
        }
        await store.signInSocial(provider: "google", authenticate: authenticate)
        check(store.session?.email == "google@example.test", "Google login")
        let owner = store.session!.userId
        await store.redeemComplimentary(code: "fixture-free-code")
        check(store.hasPaidAccess, "Entitlement")
        await store.signInSocial(provider: "apple", authenticate: authenticate)
        check(store.session?.userId == owner && store.hasPaidAccess, "Apple link preserves entitlement")
        check(store.loginProviders.allSatisfy(\.linked), "Linked provider state")
        let reloaded = AccountStore(configuration: config, service: service)
        check(reloaded.session?.userId == owner && reloaded.hasPaidAccess, "Keychain restore")
        await store.signOut()
        await store.signInSocial(provider: "apple", authenticate: authenticate)
        check(store.session?.userId == owner && store.hasPaidAccess, "Apple re-login to same account")
        await store.signOut()
        await store.signInSocial(provider: "google") { _ in URL(string: "smoothplayer-auth://complete?attempt=incorrect")! }
        check(store.session == nil, "Reject mismatched callback")
        await store.signInSocial(provider: "google") { _ in throw CancellationError() }
        check(store.session == nil && !store.busy, "Cancellation")
        await store.signInSocial(provider: "google", authenticate: authenticate)
        check(store.session?.userId == owner, "Retry after cancel")
        await store.deleteAccount()
        check(store.session == nil, "Delete")
        print("PASS: actual Swift HTTP/PKCE, Google sign-in, Apple link/re-login, same UUID/license, Keychain reload, bad callback, cancel/retry, deletion. OIDC provider and browser completion are synthetic.")
    }
}
