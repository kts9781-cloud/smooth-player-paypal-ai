import Foundation
import Observation
import Security

@MainActor @Observable
final class TrialStore {
    private(set) var ledger = TrialLedger()
    private(set) var isAvailable = true
    private(set) var hasComplimentaryAccess = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: String
    @ObservationIgnored private let featureAvailable: @MainActor () -> Bool
    @ObservationIgnored private let persistData: (Data) -> OSStatus
    @ObservationIgnored private var persistedMilliseconds: Int64 = 0
    private var fractionalMilliseconds = 0.0

    init(service: String = "com.nodelabs.smoothplayer.trial",
         featureAvailable: @escaping @MainActor () -> Bool = {
             #if os(macOS)
             return true
             #else
             return SmoothPlaybackAvailability.current.isAvailable
             #endif
         },
         persist: ((Data) -> OSStatus)? = nil) {
        self.service = service
        self.featureAvailable = featureAvailable
        self.persistData = persist ?? { data in Self.write(data, service: service) }
        hasComplimentaryAccess = Self.readComplimentaryAccess(service: service)
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let data = result as? Data,
              let stored = try? JSONDecoder().decode(TrialLedger.self, from: data) else {
            isAvailable = false
            errorMessage = SPText("체험 기록을 안전하게 읽지 못했습니다. 일반 재생은 계속 사용할 수 있습니다.")
            return
        }
        ledger = stored
        persistedMilliseconds = stored.usedMilliseconds
    }

    /// Include the sub-millisecond remainder so an exhausted in-memory trial cannot render another frame.
    var remainingMilliseconds: Int64 {
        max(0, ledger.remainingMilliseconds - (fractionalMilliseconds > 0 ? 1 : 0))
    }
    var canUseTrial: Bool { isAvailable && featureAvailable() && remainingMilliseconds > 0 }

    var canUseSmoothWithoutPurchase: Bool {
        featureAvailable() && (hasComplimentaryAccess || (isAvailable && remainingMilliseconds > 0))
    }

    private static func complimentaryQuery(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "device-complimentary-access",
         kSecAttrSynchronizable as String: false]
    }
    private static func readComplimentaryAccess(service: String) -> Bool {
        var query = complimentaryQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess && (result as? Data) == Data([1])
    }
    #if DEBUG || SMOOTH_TEST_HOST
    /// Provisioned only by a local development build. No App Store transaction is fabricated.
    func enableComplimentaryAccess() throws {
        let query = Self.complimentaryQuery(service: service)
        let values: [String: Any] = [kSecValueData as String: Data([1]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        hasComplimentaryAccess = true
    }
    #endif

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "cumulative-smooth-milliseconds",
         kSecAttrSynchronizable as String: false]
    }
    private var baseQuery: [String: Any] { Self.query(service: service) }

    private static func write(_ data: Data, service: String) -> OSStatus {
        let query = query(service: service)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecItemNotFound { return status }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }

    /// User-requested local-data deletion. Store purchases are not deleted or revoked.
    func eraseLocalData() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let grantStatus = SecItemDelete(Self.complimentaryQuery(service: service) as CFDictionary)
        guard grantStatus == errSecSuccess || grantStatus == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(grantStatus))
        }
        hasComplimentaryAccess = false
        ledger = TrialLedger()
        persistedMilliseconds = 0
        fractionalMilliseconds = 0
        isAvailable = true
        errorMessage = nil
    }

    /// Call only for time between successfully presented generated frames, never from a playback timer.
    func recordGeneratedPlayback(seconds: Double, hasPaidAccess: Bool) {
        guard isAvailable, featureAvailable(), !hasPaidAccess, !hasComplimentaryAccess, seconds.isFinite, seconds > 0,
              remainingMilliseconds > 0 else { return }
        let total = fractionalMilliseconds + min(seconds * 1_000, Double(TrialLedger.allowanceMilliseconds))
        let whole = Int64(total.rounded(.down))
        fractionalMilliseconds = total - Double(whole)
        ledger = TrialLedger(usedMilliseconds: ledger.usedMilliseconds + whole)
        if ledger.remainingMilliseconds == 0 { fractionalMilliseconds = 0 }
        // Batch frequent renderer callbacks. Normal stop/background/close must flush the remaining interval.
        if ledger.usedMilliseconds - persistedMilliseconds >= 5_000 || remainingMilliseconds == 0 { flush() }
    }

    /// Persist pending usage on stop/background/close. Failure immediately disables further free generated playback.
    @discardableResult func flush() -> Bool {
        guard isAvailable else { return false }
        if fractionalMilliseconds > 0 {
            ledger = TrialLedger(usedMilliseconds: ledger.usedMilliseconds + 1)
            fractionalMilliseconds = 0
        }
        guard ledger.usedMilliseconds != persistedMilliseconds else { return true }
        guard let data = try? JSONEncoder().encode(ledger), persistData(data) == errSecSuccess else {
            isAvailable = false
            errorMessage = SPText("체험 기록을 저장할 수 없어 부드러운 재생을 중지했습니다.")
            return false
        }
        persistedMilliseconds = ledger.usedMilliseconds
        return true
    }
}
