import Foundation

/// Stateful interleaved stereo DSP, owned by one audio scheduling actor/queue.
/// Android's filter/compressor/limiter coefficients and ramps are retained, using
/// floating output to avoid an unnecessary intermediate 16-bit quantization.
/// No delay, reverb, sample insertion or per-sample allocation is performed.
public final class AudioProcessor {
    private let sampleRate: Int
    private var profile = SoundProfile()
    public var comparison: SoundComparison = .off
    private var eqMix = 1.0, comparisonMix = 0.0, matchMix = 0.0
    private var dryEnergy = 0.0, wetEnergy = 0.0
    private var wetMatchGain = 1.0, dryMatchGain = 1.0
    private let energyRate: Double
    private var filters: [Biquad] = []
    private var previousFilters: [Biquad] = []
    private var previousMode: SoundMode = .original
    private var presetBlend = 1.0
    private var wet = 0.0
    private var width = 1.0
    private var envelope = 0.0
    private var gain = 1.0
    private var limiterGain = 1.0
    private let ramp: Double
    private let attack: Double
    private let release: Double
    private let limiterRelease: Double
    private static let ceiling = 0.9440608763 // -0.5 dBFS

    public init(sampleRate: Int = 48_000) {
        precondition(sampleRate > 6_400)
        self.sampleRate = sampleRate
        energyRate = 1 - exp(-1 / (Double(sampleRate) * 0.4))
        ramp = 1 / (Double(sampleRate) * 0.025)
        attack = exp(-1 / (Double(sampleRate) * 0.005))
        release = exp(-1 / (Double(sampleRate) * 0.180))
        limiterRelease = exp(-1 / (Double(sampleRate) * 0.080))
    }
    public func configure(_ value: SoundProfile) {
        let next = value.sanitized()
        if next.mode != profile.mode && next.mode != .original {
            previousFilters = filters; previousMode = profile.mode
            filters = filtersFor(next.mode); presetBlend = 0
        }
        profile = next
    }
    /// On seek, discard signal history while preserving the selected profile.
    public func reset() {
        filters.forEach { $0.reset() }; previousFilters.forEach { $0.reset() }
        envelope = 0; gain = 1; limiterGain = 1; wet = 0; presetBlend = 1; width = 1
        wetMatchGain = 1; dryMatchGain = 1
        eqMix = 1; comparisonMix = 0; matchMix = 0; dryEnergy = 0; wetEnergy = 0
    }
    public func process(_ pcm: inout [Float], reference: [Float]? = nil) {
        precondition(reference == nil || reference?.count == pcm.count)
        precondition(pcm.count.isMultiple(of: 2), "Interleaved stereo required")
        let customNight = profile.customNight
        let targetWet = profile.mode == .original ? 0 : customNight ? 1 : Double(profile.strength)
        let matching = comparison != .off && profile.mode != .original
        let ratio = dryEnergy > 1e-8 && wetEnergy > 1e-8 ? min(8, max(0.125, sqrt(dryEnergy / wetEnergy))) : 1
        let wetMatch = min(1, ratio), dryMatch = min(1, 1 / ratio)
        if targetWet == 0 && wet == 0 && matchMix == 0 && comparisonMix == 0 { return }
        let targetWidth = profile.spacious ? 1.25 : 1.0
        let params = customNight ? (0.10, 1 + 4 * Double(profile.nightReduction ?? 0.5), 1.0) : compression(profile.mode)
        let oldParams = compression(previousMode)
        for i in stride(from: 0, to: pcm.count, by: 2) {
            let dryL = Double(pcm[i]), dryR = Double(pcm[i + 1])
            wet = approach(wet, targetWet, ramp)
            width = approach(width, targetWidth, ramp * 0.25)
            var left = dryL, right = dryR
            for filter in filters { left = filter.process(left, 0); right = filter.process(right, 1) }
            if presetBlend < 1 {
                var oldL = dryL, oldR = dryR
                for filter in previousFilters { oldL = filter.process(oldL, 0); oldR = filter.process(oldR, 1) }
                left = oldL + (left - oldL) * presetBlend
                right = oldR + (right - oldR) * presetBlend
                presetBlend = min(1, presetBlend + ramp)
            }
            eqMix = approach(eqMix, customNight ? Double(profile.strength) : 1, ramp)
            if eqMix != 1 { left = dryL + (left - dryL) * eqMix; right = dryR + (right - dryR) * eqMix }
            let peak = max(abs(left), abs(right))
            let envCoeff = peak > envelope ? attack : release
            envelope = envCoeff * envelope + (1 - envCoeff) * peak
            let threshold = oldParams.0 + (params.0 - oldParams.0) * presetBlend
            let ratio = oldParams.1 + (params.1 - oldParams.1) * presetBlend
            let makeup = oldParams.2 + (params.2 - oldParams.2) * presetBlend
            let reduction = envelope > threshold ? pow(threshold / envelope, 1 - 1 / ratio) : 1
            let quietBoost = customNight ? 1 + 1.2 * Double(profile.nightBoost ?? 0.5) * min(1, max(0, 1 - envelope / 0.10)) : 1
            let wantedGain = reduction * makeup * quietBoost
            let gainCoeff = wantedGain < gain ? attack : release
            gain = gainCoeff * gain + (1 - gainCoeff) * wantedGain
            let mid = (left + right) * 0.5, side = (left - right) * 0.5 * width
            left = (mid + side) * gain; right = (mid - side) * gain
            let processedPeak = max(abs(left), abs(right))
            let limit = processedPeak > Self.ceiling ? Self.ceiling / processedPeak : 1
            limiterGain = limit < limiterGain ? limit : limiterRelease * limiterGain + (1 - limiterRelease) * limit
            left = dryL + (left * limiterGain - dryL) * wet
            right = dryR + (right * limiterGain - dryR) * wet
            let originalL = reference.map { Double($0[i]) } ?? dryL
            let originalR = reference.map { Double($0[i + 1]) } ?? dryR
            dryEnergy += energyRate * ((originalL * originalL + originalR * originalR) * 0.5 - dryEnergy)
            wetEnergy += energyRate * ((left * left + right * right) * 0.5 - wetEnergy)
            matchMix = approach(matchMix, matching ? 1 : 0, ramp)
            comparisonMix = approach(comparisonMix, matching && comparison == .original ? 1 : 0, ramp)
            wetMatchGain = approach(wetMatchGain, wetMatch, ramp * 0.125)
            dryMatchGain = approach(dryMatchGain, dryMatch, ramp * 0.125)
            left *= 1 + (wetMatchGain - 1) * matchMix; right *= 1 + (wetMatchGain - 1) * matchMix
            left += (originalL * (1 + (dryMatchGain - 1) * matchMix) - left) * comparisonMix
            right += (originalR * (1 + (dryMatchGain - 1) * matchMix) - right) * comparisonMix
            // Android's final integer quantization clamps to this same representable range.
            pcm[i] = Float(min(32767.0 / 32768.0, max(-1, left)))
            pcm[i + 1] = Float(min(32767.0 / 32768.0, max(-1, right)))
        }
    }
    private func compression(_ mode: SoundMode) -> (Double, Double, Double) {
        switch mode {
        case .original: (1, 1, 1)
        case .cinema: (0.50, 1.6, 1.08)
        case .dialogue: (0.25, 2.2, 1.35)
        case .night: (0.10, 5, 2.20)
        }
    }
    private func filtersFor(_ mode: SoundMode) -> [Biquad] {
        switch mode {
        case .original: []
        case .cinema: [.peak(160, 0.7, 5, sampleRate), .peak(600, 0.8, -1.5, sampleRate), .peak(3200, 0.8, 3, sampleRate)]
        case .dialogue: [.peak(200, 0.7, -5, sampleRate), .peak(2300, 0.8, 5, sampleRate)]
        case .night: [.peak(120, 0.7, -5, sampleRate), .peak(2000, 0.8, 2.5, sampleRate)]
        }
    }
    private func approach(_ current: Double, _ target: Double, _ step: Double) -> Double {
        current < target ? min(current + step, target) : max(current - step, target)
    }
    private final class Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = [0.0, 0.0], z2 = [0.0, 0.0]
        init(_ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) {
            self.b0=b0; self.b1=b1; self.b2=b2; self.a1=a1; self.a2=a2
        }
        func process(_ x: Double, _ channel: Int) -> Double {
            let y = b0 * x + z1[channel]
            z1[channel] = b1 * x - a1 * y + z2[channel]
            z2[channel] = b2 * x - a2 * y
            return y
        }
        func reset() { z1 = [0,0]; z2 = [0,0] }
        static func peak(_ hz: Double, _ q: Double, _ db: Double, _ rate: Int) -> Biquad {
            let a = pow(10, db / 40), omega = 2 * Double.pi * hz / Double(rate)
            let alpha = sin(omega) / (2 * q), c = cos(omega), a0 = 1 + alpha / a
            return Biquad((1 + alpha * a) / a0, -2 * c / a0, (1 - alpha * a) / a0, -2 * c / a0, (1 - alpha / a) / a0)
        }
    }
}
