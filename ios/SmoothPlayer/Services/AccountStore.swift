import Foundation
import Observation
import Security
import CryptoKit

private final class AccountRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AccountConfiguration: Sendable {
    let origin: URL
    let publicKey: String
    let environment: String

    static var bundled: AccountConfiguration? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let raw = info["SmoothAccountURL"] as? String, let url = URL(string: raw),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let key = info["SmoothAccountPublicKey"] as? String, !key.isEmpty else { return nil }
        let environment = info["SmoothAccountEnvironment"] as? String ?? "production"
        #if DEBUG || SMOOTH_ACCOUNT_TEST
        let allowed = environment == "production" || environment == "test"
        let transport = url.scheme == "https" || (environment == "test" && url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? ""))
        #else
        let allowed = environment == "production"
        let transport = url.scheme == "https"
        #endif
        guard allowed, transport else { return nil }
        return AccountConfiguration(origin: url, publicKey: key, environment: environment)
    }
}

@MainActor @Observable
final class AccountStore {
    struct Session: Codable { let token: String; let userId: String; let email: String; let expiresAt: Double }
    struct LoginProvider: Decodable, Identifiable {
        let id: String; let enabled: Bool; let linked: Bool
        var title: String { id == "apple" ? "Apple" : "Google" }
    }
    private(set) var loginProviders = [LoginProvider(id: "google", enabled: false, linked: false), LoginProvider(id: "apple", enabled: false, linked: false)]
    private struct Reply: Decodable { let license: AccountLicenseEnvelope; let email: String; let userId: String; let isAdmin: Bool? }
    private struct Saved: Codable { let session: Session; let license: AccountLicenseEnvelope?; let origin: String; let environment: String }
    private(set) var session: Session?
    private(set) var license: AccountLicenseEnvelope?
    private(set) var busy = false
    private(set) var message: String?
    private(set) var challengeId: String?
    private(set) var revision = 0
    private(set) var isAdmin = false
    var nasSync: NASAccountSync?
    private var verifiedLicense: AccountLicense?
    @ObservationIgnored let configuration: AccountConfiguration?
    @ObservationIgnored private let service: String
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var licenseRevision = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let transport = URLSession(configuration: .ephemeral, delegate: AccountRedirectPolicy(), delegateQueue: nil)

    init(configuration: AccountConfiguration? = .bundled, service: String = "com.nodelabs.smoothplayer.account") {
        self.configuration = configuration; self.service = service
        guard let configuration, let data = Self.read(service: service),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.origin == configuration.origin.absoluteString, saved.environment == configuration.environment else { return }
        session = saved.session; license = saved.license
        if let envelope = saved.license {
            verifiedLicense = AccountLicense.verified(envelope, publicKey: configuration.publicKey, issuer: configuration.origin.absoluteString,
                environment: configuration.environment, subject: saved.session.userId)
        }
    }

    var isConfigured: Bool { configuration != nil }
    var userID: UUID? { session.flatMap { UUID(uuidString: $0.userId) } }
    var hasPaidAccess: Bool {
        _ = revision
        guard let session, let verifiedLicense, verifiedLicense.subject == session.userId,
              verifiedLicense.issuedAt <= Date().timeIntervalSince1970 + 60,
              verifiedLicense.expiresAt > Date().timeIntervalSince1970 else { return false }
        return !verifiedLicense.products.isEmpty
    }
    var purchaseURL: URL? { configuration?.origin }

    func start() async {
        guard loop == nil else { return }
        await refresh()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                self.revision += 1
                if !self.busy { await self.refresh() }
            }
        }
    }

    func requestCode(email: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        struct Reply: Decodable { let challengeId: String; let message: String }
        do {
            let result: Reply = try await request("auth/code", body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines)])
            challengeId = result.challengeId; message = SPServerText(result.message)
        } catch { message = error.localizedDescription }
    }

    func signIn(code: String) async {
        guard !busy, let challengeId else { return }; busy = true; defer { busy = false }
        do {
            let result: Session = try await request("auth/verify", body: ["challengeId": challengeId, "code": code])
            generation += 1; isAdmin = false; session = result; license = nil; verifiedLicense = nil; self.challengeId = nil
            try persist(); nasSync?.accountChanged(); await refresh(); await loadLoginProviders(); message = SPText("로그인했습니다.")
        } catch { message = error.localizedDescription }
    }

    func loadLoginProviders() async {
        guard isConfigured else { return }
        let current = generation
        struct Providers: Decodable { let providers: [LoginProvider] }
        do {
            let result: Providers = try await request("auth/providers")
            guard generation == current else { return }
            loginProviders = result.providers.filter { ["google", "apple"].contains($0.id) }
        } catch {
            if generation == current { message = error.localizedDescription }
        }
    }

    /// The browser receives only a one-time request ID. The session is redeemed
    /// here with a verifier which never leaves the original app/browser context.
    func signInSocial(provider: String, authenticate: (URL) async throws -> URL) async {
        guard !busy, let configuration, loginProviders.contains(where: { $0.id == provider && $0.enabled && !$0.linked }) else { return }
        busy = true; message = nil; defer { busy = false }
        let current = generation, ownerToken = session?.token
        struct Start: Decodable { let id: String; let authorizationURL: URL }
        struct Completion: Decodable { let status: String; let session: Session? }
        do {
            var bytes = [UInt8](repeating: 0, count: 48)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AccountError(SPText("안전한 로그인 요청을 만들지 못했습니다.")) }
            func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
            let verifier = base64URL(Data(bytes))
            let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            let start: Start = try await request("auth/social/start", body: ["provider": provider, "challenge": challenge, "client": "apple"])
            guard UUID(uuidString: start.id) != nil,
                  start.authorizationURL == configuration.origin.appendingPathComponent("v1/auth/social/browser/" + start.id) else { throw AccountError(SPText("로그인 주소를 확인하지 못했습니다.")) }
            let callback = try await authenticate(start.authorizationURL)
            let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard callback.scheme == "smoothplayer-auth", callback.host == "complete", query.count == 1,
                  query.first?.name == "attempt", query.first?.value == start.id,
                  generation == current, session?.token == ownerToken else { throw AccountError(SPText("로그인 요청이 변경되었습니다. 다시 시도해 주세요.")) }
            let result: Completion = try await request("auth/social/complete", body: ["id": start.id, "verifier": verifier])
            guard generation == current, session?.token == ownerToken, result.status == "complete", let signedIn = result.session,
                  ownerToken == nil || signedIn.userId == session?.userId else { throw AccountError(SPText("로그인을 완료하지 못했습니다. 다시 시도해 주세요.")) }
            let previous = (session, license, verifiedLicense)
            session = signedIn; license = nil; verifiedLicense = nil
            do { try persist() } catch {
                (session, license, verifiedLicense) = previous
                throw error
            }
            generation += 1; isAdmin = false; challengeId = nil
            nasSync?.accountChanged(); await refresh(); await loadLoginProviders()
            guard session?.userId == signedIn.userId else { return }
            message = ownerToken == nil ? SPText("로그인했습니다.") : SPText("로그인 방식을 기존 계정에 연결했습니다.")
        } catch {
            if generation == current { message = error.localizedDescription }
        }
    }

    func refresh() async {
        guard session != nil, isConfigured else { return }
        let current = generation
        let currentLicense = licenseRevision
        do {
            let reply: Reply = try await request("me")
            guard generation == current, licenseRevision == currentLicense else { return }
            try accept(reply)
        } catch {
            if generation == current {
                if (error as? AccountError)?.status == 401 {
                    generation += 1
                    session = nil; isAdmin = false; license = nil; verifiedLicense = nil; revision += 1
                    nasSync?.accountChanged()
                    SecItemDelete(Self.query(service: service) as CFDictionary)
                }
                message = error.localizedDescription
            }
            // Retain only the previously signed, bounded lease when offline.
        }
    }

    func linkApple(signedTransaction: String) async throws {
        guard session != nil else { throw AccountError(SPText("먼저 이메일 계정으로 로그인해 주세요.")) }
        let current = generation
        let reply: Reply = try await request("purchases/apple", body: ["signedTransaction": signedTransaction])
        guard generation == current else { throw AccountError(SPText("계정이 변경되었습니다. 다시 연결해 주세요.")) }
        try accept(reply); message = SPText("기존 구매를 계정에 연결했습니다.")
    }

    #if os(macOS)
    func redeemComplimentary(code: String) async {
        guard !busy, session != nil else { return }; busy = true; defer { busy = false }
        let current = generation
        do {
            let reply: Reply = try await request("complimentary/redeem", body: ["code": code.trimmingCharacters(in: .whitespacesAndNewlines)])
            guard generation == current else { return }
            try accept(reply)
            message = SPText("무료 평생 이용권이 계정에 등록되었습니다. 토스 자동 갱신은 중단됩니다.")
        } catch { if generation == current { message = error.localizedDescription } }
    }
    #endif

    func signOut() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let oldToken = session?.token
        generation += 1; session = nil; isAdmin = false; license = nil; verifiedLicense = nil; revision += 1
        nasSync?.accountChanged()
        SecItemDelete(Self.query(service: service) as CFDictionary)
        if let oldToken { let _: EmptyReply? = try? await request("auth/logout", body: [:], token: oldToken) }
        await loadLoginProviders()
        message = SPText("로그아웃했습니다.")
    }

    func deleteAccount() async {
        guard !busy else { return }; busy = true
        do {
            let _: EmptyReply = try await request("account", method: "DELETE")
            var cleared = true
            do { try nasSync?.eraseCurrentAccount() } catch { cleared = false }
            busy = false; await signOut()
            message = cleared ? SPText("계정을 삭제했습니다. Apple·Google 구독은 해당 스토어에서 별도로 해지해 주세요.") : SPText("계정은 삭제했습니다. 기기의 NAS 캐시 정리를 완료하지 못했습니다.")
        } catch { busy = false; message = error.localizedDescription }
    }

    private func accept(_ reply: Reply) throws {
        guard let configuration, let session, reply.userId == session.userId,
              let verified = AccountLicense.verified(reply.license, publicKey: configuration.publicKey,
                issuer: configuration.origin.absoluteString, environment: configuration.environment, subject: session.userId) else {
            throw AccountError(SPText("이용권 서명을 확인하지 못했습니다."))
        }
        license = reply.license; verifiedLicense = verified; licenseRevision += 1; isAdmin = reply.isAdmin == true; revision += 1; try persist()
    }

    func adminOverview() async throws -> AdminOverview {
        guard isAdmin, let owner = session else { throw AccountError(SPText("관리자 계정만 현황을 확인할 수 있습니다.")) }
        let current = generation
        do {
            let result: AdminOverview = try await request("admin/overview", token: owner.token)
            guard generation == current, session?.token == owner.token, isAdmin else {
                throw AccountError(SPText("계정이 변경되었습니다."))
            }
            return result
        } catch {
            if generation == current, let status = (error as? AccountError)?.status, status == 401 || status == 403 { isAdmin = false }
            throw error
        }
    }

    private struct EmptyReply: Decodable {}
    private struct AccountError: LocalizedError {
        let errorDescription: String?
        let status: Int?
        init(_ text: String, status: Int? = nil) { errorDescription = text; self.status = status }
    }

    func syncNAS(_ body: NASCloudRequest) async throws -> NASCloudReply {
        guard let session else { throw AccountError(SPText("로그인이 필요합니다.")) }
        let owner = session.userId
        let reply: NASCloudReply = try await requestData("nas/sync", method: "POST", data: JSONEncoder().encode(body), token: session.token, limit: 1048576)
        guard self.session?.userId == owner else { throw AccountError(SPText("계정이 변경되었습니다.")) }
        return reply
    }

    private func request<T: Decodable>(_ path: String, method: String? = nil, body: [String: String]? = nil, token: String? = nil) async throws -> T {
        try await requestData(path, method: method ?? (body == nil ? "GET" : "POST"), data: body.map { try JSONEncoder().encode($0) }, token: token, limit: 65536)
    }
    private func requestData<T: Decodable>(_ path: String, method: String, data: Data?, token: String?, limit: Int) async throws -> T {
        guard let configuration else { throw AccountError(SPText("계정 서비스를 준비하고 있습니다. 기존 기기 내 구매 복원은 계속 사용할 수 있습니다.")) }
        var request = URLRequest(url: configuration.origin.appendingPathComponent("v1/" + path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = token ?? session?.token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = data
        let (data, response) = try await transport.data(for: request)
        guard data.count <= limit, let http = response as? HTTPURLResponse else { throw AccountError(SPText("서버 응답을 확인하지 못했습니다.")) }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["message"]
            throw AccountError(message.map(SPServerText) ?? SPText("요청을 완료하지 못했습니다."), status: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func persist() throws {
        guard let session, let configuration else { return }
        let data = try JSONEncoder().encode(Saved(session: session, license: license, origin: configuration.origin.absoluteString, environment: configuration.environment))
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let query = Self.query(service: service)
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw AccountError(SPText("로그인 정보를 안전하게 저장하지 못했습니다.")) }
    }
    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session", kSecAttrSynchronizable as String: false]
    }
    private static func read(service: String) -> Data? {
        var query = query(service: service); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    deinit { loop?.cancel(); transport.invalidateAndCancel() }
}
