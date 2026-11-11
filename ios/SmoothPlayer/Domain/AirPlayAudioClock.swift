import Foundation

/// A bounded copy of the audio-master clock. The sender never waits for the UI actor.
/// Short UI/render stalls may extrapolate; a stale or invalid clock must send silence.
final class AirPlayAudioClock: @unchecked Sendable {
    struct State: Sendable {
        let time: Double
        let playing: Bool
        let volume: Float
        let generation: Int
    }
    private let lock = NSLock()
    private let maximumAge: Double
    private var mediaTime = 0.0
    private var hostTime = 0.0
    private var playing = false
    private var volume: Float = 1
    private var valid = false
    private var generation = 0
    private var updates = 0
    private var invalidations = 0
    private var invalidUpdates = 0
    private var staleReads = 0
    private var pausedReads = 0
    private var invalidReads = 0
    private var advancingReads = 0
    private var maximumAnchorGap = 0.0
    private var maximumAnchorCorrection = 0.0
    private var maximumReadAge = 0.0

    init(maximumAge: Double = 0.2) { self.maximumAge = maximumAge }

    func update(time: Double, playing: Bool, volume: Float, now: Double) {
        lock.lock(); defer { lock.unlock() }
        updates += 1
        guard time.isFinite, abs(time) < 1e10, now.isFinite else {
            invalidUpdates += 1
            valid = false; generation += 1; return
        }
        if valid {
            let gap = now - hostTime
            if gap.isFinite, gap >= 0 {
                maximumAnchorGap = max(maximumAnchorGap, gap)
                if self.playing, playing {
                    maximumAnchorCorrection = max(maximumAnchorCorrection, abs(time - mediaTime - gap))
                }
            }
        }
        if !valid || self.playing != playing { generation += 1 }
        mediaTime = time; hostTime = now; self.playing = playing
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 1
        valid = true
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        invalidations += 1
        valid = false; generation += 1
    }

    func read(now sampleHostTime: @autoclosure () -> Double) -> State {
        lock.lock(); defer { lock.unlock() }
        // Sample under the same lock as the anchor. Sampling at the call site
        // lets a concurrent update publish a newer hostTime before this read,
        // creating a negative age and a false one-block pause/converter reset.
        let now = sampleHostTime()
        let age = now - hostTime
        let advancing = valid && playing && age.isFinite && age >= 0 && age <= maximumAge
        if valid, age.isFinite, age >= 0 { maximumReadAge = max(maximumReadAge, age) }
        if advancing { advancingReads += 1 }
        else if valid, !playing { pausedReads += 1 }
        else if valid, playing, age.isFinite, age > maximumAge { staleReads += 1 }
        else { invalidReads += 1 }
        return State(time: mediaTime + (advancing ? age : 0), playing: advancing,
                     volume: volume, generation: generation)
    }

    /// Numeric counters only: no media position, PCM, file/receiver identity or credentials.
    func diagnosticMetrics() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        return ["clock_volume": Double(volume), "clock_updates": Double(updates), "clock_invalidations": Double(invalidations),
                "clock_invalid_updates": Double(invalidUpdates), "clock_stale_reads": Double(staleReads),
                "clock_paused_reads": Double(pausedReads), "clock_invalid_reads": Double(invalidReads),
                "clock_advancing_reads": Double(advancingReads), "clock_max_anchor_gap_ms": maximumAnchorGap * 1000,
                "clock_max_anchor_correction_ms": maximumAnchorCorrection * 1000,
                "clock_max_read_age_ms": maximumReadAge * 1000]
    }

    func resetDiagnostics() {
        lock.lock(); defer { lock.unlock() }
        updates = 0; invalidations = 0; invalidUpdates = 0; staleReads = 0
        pausedReads = 0; invalidReads = 0; advancingReads = 0
        maximumAnchorGap = 0; maximumAnchorCorrection = 0; maximumReadAge = 0
    }
}
