import Foundation

/// Eligibility uses original stream metadata, never the interpolation proxy size.
/// Unknown/HDR/interlaced/anamorphic streams retain the established renderer.
struct LowResolutionSource: Sendable, Equatable {
    var width: Int
    var height: Int
    var verifiedSDR: Bool
    func status(texture: CGSize, output: CGSize, outputFPS: Double = 60) -> String? {
        guard width > 0, height > 0, verifiedSDR else { return SPText("영상 정보 미확인 · 기본 보정") }
        guard min(width, height) <= 480, max(width, height) <= 960 else { return SPText("고해상도 원본 · 기본 보정") }
        guard texture.width > 0, texture.height > 0, output.width.isFinite, output.height.isFinite else { return SPText("영상 준비 중") }
        // Compare both orientations; an HD proxy cannot make an SD eligibility decision.
        guard abs(Double(min(width, height)) - min(texture.width, texture.height)) <= 1,
              abs(Double(max(width, height)) - max(texture.width, texture.height)) <= 1 else { return SPText("처리 크기 변경 · 기본 보정") }
        let sx = output.width / texture.width, sy = output.height / texture.height
        guard sx > 1, sy > 1 else { return SPText("원본 크기·축소 재생 · 기본 보정") }
        guard abs(sx - sy) <= 0.01 * min(sx, sy) else { return SPText("늘리기 · 기본 보정") }
        guard outputFPS.isFinite, outputFPS > 0 else { return SPText("출력 속도 미확인 · 기본 보정") }
        // M1 Max 1080p/120 A/B exceeded the 3% regression budget. Keep the same
        // conservative gate on unqualified devices; never lower interpolation FPS.
        guard outputFPS <= 60 else { return SPText("부드러운 재생 우선 · 기본 보정") }
        guard max(sx, sy) <= 4, output.width * output.height <= 2560 * 1440 else { return SPText("확대 범위 초과 · 기본 보정") }
        return nil
    }
}

/// Matches Android's UpscaleMode; this is spatial reconstruction, not AI super-resolution.
enum VideoEnhancementMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, natural, sharp, restore, restoreSharp
    var id: Self { self }
    var label: String {
        switch self { case .off: SPText("끔"); case .natural: SPText("자연스럽게"); case .sharp: SPText("선명하게"); case .restore: SPText("뭉개짐 완화"); case .restoreSharp: SPText("뭉개짐 완화 + 선명하게") }
    }
    var detail: String {
        switch self {
        case .off: SPText("기본 확대 방식으로 재생합니다.")
        case .natural: SPText("확대할 때 흐려지는 윤곽을 자연스럽게 보정합니다.")
        case .sharp: SPText("영상의 윤곽을 강조합니다. 원본 크기나 축소 재생에도 적용합니다.")
        case .restore: SPText("약한 압축 자국을 줄입니다. 사라진 세부 내용을 복원하는 기능은 아닙니다.")
        case .restoreSharp: SPText("약한 압축 자국을 줄이면서 윤곽을 더 선명하게 보정합니다.")
        }
    }
    var sharpEnabled: Bool { self == .sharp || self == .restoreSharp }
    var cleanupEnabled: Bool { self == .restore || self == .restoreSharp }
    func settingSharp(_ enabled: Bool) -> Self {
        if enabled { return cleanupEnabled ? .restoreSharp : .sharp }
        return cleanupEnabled ? .restore : (self == .off ? .off : .natural)
    }
    func settingCleanup(_ enabled: Bool) -> Self {
        if enabled { return sharpEnabled ? .restoreSharp : .restore }
        return sharpEnabled ? .sharp : (self == .off ? .off : .natural)
    }
    static func stored(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .natural }
}

/// Render-thread state. Automatic reductions last until a different selection or a new playback.
/// Observe actual GPU/presentation delay only after seek/rebuffer/startup has settled.
struct VideoEnhancementBudget: Sendable {
    enum ReductionReason: Sendable, Equatable { case performance, thermal }
    private(set) var requested: VideoEnhancementMode
    private(set) var effective: VideoEnhancementMode
    private(set) var automaticReduction = true
    private(set) var reductionReason: ReductionReason?
    private var warmup = 90
    private var samples = 0
    private var late = 0
    private(set) var lowResolutionLimited = false
    var lowResolutionRequested = false
    var isLimited: Bool { effective != requested }
    var limitationDescription: String {
        if reductionReason == .thermal { return SPText("발열을 줄이기 위해 보정을 멈췄습니다.") }
        return automaticReduction ? SPText("자동 조절로 보정을 낮췄습니다.") : SPText("프레임 유지를 위해 보정을 낮췄습니다.")
    }

    init(mode: VideoEnhancementMode = .natural, automaticReduction: Bool = true) {
        requested = mode; effective = mode; self.automaticReduction = automaticReduction
    }

    mutating func setAutomaticReduction(_ enabled: Bool) {
        guard automaticReduction != enabled else { return }
        self = Self(mode: requested, automaticReduction: enabled)
    }

    mutating func select(_ mode: VideoEnhancementMode) {
        guard requested != mode else { return }
        self = Self(mode: mode, automaticReduction: automaticReduction)
    }

    /// Check before submitting pixels too: protection must not wait for a presented
    /// callback, and maintaining a selected effect must never bypass serious heat.
    mutating func applyThermalLimit(_ limited: Bool) {
        guard limited else { return }
        effective = .off
        lowResolutionLimited = true
        reductionReason = .thermal
        samples = 0; late = 0
    }

    /// `thermalLimited` corresponds to iOS serious/critical, Android severe or higher.
    /// Maintained quality tolerates transient contention, but sustained missed frame
    /// deadlines still yield to playback. Requested/stored settings remain unchanged.
    mutating func observe(delayMilliseconds: Double, refreshRate: Double, thermalLimited: Bool, stable: Bool,
                          lateThresholdMilliseconds: Double? = nil) {
        applyThermalLimit(thermalLimited)
        guard stable, effective != .off else { samples = 0; late = 0; return }
        guard delayMilliseconds.isFinite, delayMilliseconds >= 0, refreshRate.isFinite, refreshRate > 0 else { return }
        let threshold = lateThresholdMilliseconds ?? max(8, 800 / min(120, max(24, refreshRate)))
        guard threshold.isFinite, threshold > 0 else { return }
        if warmup > 0 { warmup -= 1; return }
        if delayMilliseconds > threshold { late += 1 }
        samples += 1
        if samples >= 120 {
            if late >= (automaticReduction ? 15 : 60) {
                // Discard the optional SD work first; retain existing manual effects.
                if lowResolutionRequested && !lowResolutionLimited { lowResolutionLimited = true }
                else {
                    effective = (effective.sharpEnabled || effective.cleanupEnabled) ? .natural : .off
                    reductionReason = .performance
                }
            }
            samples = 0; late = 0
        }
    }
}
