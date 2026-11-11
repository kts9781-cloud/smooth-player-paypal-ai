import Foundation

/// Processing choices shared with Android. Original bypasses every effect,
/// including stereo width; this is not Atmos or dialogue source separation.
public enum SoundMode: String, Codable, CaseIterable, Sendable {
    case original = "ORIGINAL", cinema = "CINEMA", dialogue = "DIALOGUE", night = "NIGHT"
    public var label: String {
        switch self {
        case .original: SPText("원음")
        case .cinema: SPText("영화")
        case .dialogue: SPText("대사 강조")
        case .night: SPText("야간")
        }
    }
    public var description: String {
        switch self {
        case .original: SPText("추가 보정 없이 원래 소리로")
        case .cinema: SPText("묵직한 저음과 선명한 디테일")
        case .dialogue: SPText("배경의 울림을 줄이고 말소리를 또렷하게")
        case .night: SPText("큰 효과음은 부드럽게, 작은 대사는 잘 들리게")
        }
    }
    public static func fromStored(_ value: String?) -> SoundMode {
        value.flatMap(SoundMode.init(rawValue:)) ?? .original
    }
}

public struct SoundProfile: Codable, Equatable, Sendable {
    public var mode: SoundMode
    public var strength: Float
    public var spacious: Bool
    /// nil preserves the existing wet/dry night preset on upgrade.
    public var nightReduction: Float?
    public var nightBoost: Float?
    public var customNight: Bool { mode == .night && (nightReduction != nil || nightBoost != nil) }
    public init(mode: SoundMode = .original, strength: Float = 0.65, spacious: Bool = false,
                nightReduction: Float? = nil, nightBoost: Float? = nil) {
        self.mode = mode; self.strength = strength; self.spacious = spacious
        self.nightReduction = nightReduction; self.nightBoost = nightBoost
    }
    public func sanitized() -> SoundProfile {
        func bounded(_ value: Float?) -> Float? { value.map { $0.isFinite ? min(1, max(0, $0)) : 0.5 } }
        return SoundProfile(mode: mode, strength: strength.isFinite ? min(1, max(0, strength)) : 0.65, spacious: spacious,
                            nightReduction: bounded(nightReduction), nightBoost: bounded(nightBoost))
    }
}

/// User-selected listening profiles, not automatic hardware detection or acoustic calibration.
public enum SoundPresetTarget: String, Codable, CaseIterable, Sendable {
    case standard, speaker, headphones, tv
    public var label: String {
        switch self { case .standard: SPText("기본"); case .speaker: SPText("내장 스피커"); case .headphones: SPText("이어폰"); case .tv: "TV" }
    }
    public var initialProfile: SoundProfile {
        switch self {
        case .standard: SoundProfile()
        case .speaker: SoundProfile(mode: .dialogue, strength: 0.55)
        case .headphones: SoundProfile(mode: .cinema, strength: 0.5, spacious: true)
        case .tv: SoundProfile(mode: .cinema, strength: 0.65)
        }
    }
}

/// Ephemeral audition state; never persisted as the user's sound choice.
public enum SoundComparison: String, Sendable { case off, processed, original }
