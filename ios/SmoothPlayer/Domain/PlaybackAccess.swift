import Foundation

public enum SmoothProduct: String, CaseIterable, Sendable {
    case monthly = "smooth_monthly"
    case yearly = "smooth_yearly"
    case lifetime = "smooth_lifetime"
}

/// An availability decision must come from an implemented, validated renderer, not an IAP flag.
public enum SmoothCapability: Equatable, Sendable {
    case unavailable(reason: String)
    case supported

    public var isAvailable: Bool {
        if case .supported = self { return true }
        return false
    }

}

/// Facts about this runtime, without a unique device identifier or an inferred chip family.
public struct SmoothDeviceEnvironment: Equatable, Sendable {
    public enum Platform: Equatable, Sendable {
        case physicalIOS, simulator, macCatalyst, iOSAppOnMac
    }

    public let platform: Platform
    public let modelIdentifier: String
    public let operatingSystemMajorVersion: Int
    public let hasMetalDevice: Bool
    public let hasBundledModel: Bool
    public let maximumFramesPerSecond: Int

    public init(platform: Platform, modelIdentifier: String, operatingSystemMajorVersion: Int,
                hasMetalDevice: Bool, hasBundledModel: Bool, maximumFramesPerSecond: Int) {
        self.platform = platform
        self.modelIdentifier = modelIdentifier
        self.operatingSystemMajorVersion = operatingSystemMajorVersion
        self.hasMetalDevice = hasMetalDevice
        self.hasBundledModel = hasBundledModel
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }
}

/// Approval is a release decision, never inferred from a purchase or a matching device.
public enum SmoothReleaseApproval: Equatable, Sendable {
    case pendingQualification
    case qualifiedIPad166
}

public enum SmoothEligibilityFailure: Equatable, Sendable {
    case unsupportedPlatform, unverifiedModel, operatingSystem, metal, modelResource, displayRefreshRate

    public var reason: String {
        switch self {
        case .unsupportedPlatform: SPText("이 환경에서는 부드러운 재생을 지원하지 않습니다. 일반 재생은 사용할 수 있습니다.")
        case .unverifiedModel: SPText("이 기기는 부드러운 재생 지원이 확인되지 않았습니다. 일반 재생은 사용할 수 있습니다.")
        case .operatingSystem: SPText("부드러운 재생에는 iOS 또는 iPadOS 18 이상이 필요합니다.")
        case .metal: SPText("이 기기에서 부드러운 재생에 필요한 그래픽 기능을 사용할 수 없습니다.")
        case .modelResource: SPText("부드러운 재생에 필요한 앱 파일을 찾지 못했습니다.")
        case .displayRefreshRate: SPText("이 화면에서는 검증된 부드러운 재생 모드를 사용할 수 없습니다.")
        }
    }
}

/// One decision supplies storefront/paywall and player eligibility. Compatibility
/// playback may exercise unqualified models without enabling StoreKit purchases.
public struct SmoothAvailabilityDecision: Equatable, Sendable {
    public let purchaseCapability: SmoothCapability
    public let playbackCapability: SmoothCapability
    public let deviceFailure: SmoothEligibilityFailure?
    public let isDevicePreview: Bool

    // Capability does not imply a user preference. A newly configured player (or
    // one not yet given saved preferences) must keep the product's 60 fps default.
    public var preferredOutputFramesPerSecond: Int { 60 }
}

public enum SmoothEligibilityPolicy {
    // The release owner may change this only after accepting the completed qualification evidence.
    // Matching hardware, Debug builds and verified purchases cannot change this decision.
    public static let releaseApproval: SmoothReleaseApproval = .qualifiedIPad166
    public static let verifiedModelIdentifier = "iPad16,6"
    public static var releasePendingReason: String { SPText("부드러운 재생의 출시 검증을 진행 중입니다. 아직 이용권을 판매하지 않습니다.") }

    public static func evaluate(_ environment: SmoothDeviceEnvironment,
                                approval: SmoothReleaseApproval = SmoothEligibilityPolicy.releaseApproval,
                                allowsDevelopmentPreview: Bool = false,
                                allowsCompatibilityPlayback: Bool = false) -> SmoothAvailabilityDecision {
        let failure: SmoothEligibilityFailure?
        if environment.platform != .physicalIOS { failure = .unsupportedPlatform }
        else if !allowsCompatibilityPlayback && environment.modelIdentifier != verifiedModelIdentifier { failure = .unverifiedModel }
        else if environment.operatingSystemMajorVersion < 18 { failure = .operatingSystem }
        else if !environment.hasMetalDevice { failure = .metal }
        else if !environment.hasBundledModel { failure = .modelResource }
        else if environment.maximumFramesPerSecond < (allowsCompatibilityPlayback ? 60 : 120) { failure = .displayRefreshRate }
        else { failure = nil }

        if let failure {
            let unavailable = SmoothCapability.unavailable(reason: failure.reason)
            return SmoothAvailabilityDecision(purchaseCapability: unavailable, playbackCapability: unavailable,
                                              deviceFailure: failure, isDevicePreview: false)
        }
        if approval == .qualifiedIPad166 && environment.modelIdentifier == verifiedModelIdentifier && environment.maximumFramesPerSecond >= 120 {
            return SmoothAvailabilityDecision(purchaseCapability: .supported, playbackCapability: .supported,
                                              deviceFailure: nil, isDevicePreview: false)
        }
        let pending = SmoothCapability.unavailable(reason: releasePendingReason)
        return SmoothAvailabilityDecision(purchaseCapability: pending,
                                          playbackCapability: allowsDevelopmentPreview || allowsCompatibilityPlayback ? .supported : pending,
                                          deviceFailure: nil, isDevicePreview: allowsDevelopmentPreview || allowsCompatibilityPlayback)
    }
}

public struct TrialLedger: Codable, Equatable, Sendable {
    public static let allowanceMilliseconds: Int64 = 600_000
    public private(set) var usedMilliseconds: Int64

    public init(usedMilliseconds: Int64 = 0) {
        self.usedMilliseconds = min(max(0, usedMilliseconds), Self.allowanceMilliseconds)
    }

    public var remainingMilliseconds: Int64 { Self.allowanceMilliseconds - usedMilliseconds }

    /// Only the renderer may charge intervals in which it actually presented generated frames.
    public mutating func record(seconds: Double, generatedFramesPresented: Bool, hasPaidAccess: Bool) {
        guard generatedFramesPresented, !hasPaidAccess, seconds.isFinite, seconds > 0 else { return }
        let bounded = min(seconds, Double(Self.allowanceMilliseconds) / 1_000)
        let milliseconds = Int64((bounded * 1_000).rounded(.up))
        usedMilliseconds = min(Self.allowanceMilliseconds, usedMilliseconds + milliseconds)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try values.decode(Int64.self, forKey: .usedMilliseconds)
        // A malformed stored counter cannot silently give a fresh trial.
        guard (0...Self.allowanceMilliseconds).contains(stored) else {
            throw DecodingError.dataCorruptedError(forKey: .usedMilliseconds, in: values, debugDescription: "Invalid trial usage")
        }
        usedMilliseconds = stored
    }
}

public struct PlaybackAccess: Sendable {
    public let capability: SmoothCapability
    public let verifiedProductIDs: Set<String>
    public let trial: TrialLedger
    public let trialStorageAvailable: Bool

    public init(capability: SmoothCapability, verifiedProductIDs: Set<String>, trial: TrialLedger, trialStorageAvailable: Bool = true) {
        self.capability = capability
        self.verifiedProductIDs = verifiedProductIDs
        self.trial = trial
        self.trialStorageAvailable = trialStorageAvailable
    }

    public var hasPaidAccess: Bool {
        SmoothProduct.allCases.contains { verifiedProductIDs.contains($0.rawValue) }
    }

    public var canGenerateFrames: Bool {
        capability.isAvailable && (hasPaidAccess || (trialStorageAvailable && trial.remainingMilliseconds > 0))
    }

    public var canOfferPurchase: Bool { capability.isAvailable && !hasPaidAccess }
}
