import Foundation

/// The same sustained-pressure policy as Android's TV encoder; never changes playback preferences.
struct AirPlayBitrateBudget {
    private(set) var bitrate = 32_000_000
    private var windowStart = -1.0
    private var previous = -1.0
    private var samples = 0, late = 0, stalled = 0
    private var pressureSince = -1.0, previousPressureSample = -1.0, lastPressureReduction = -Double.infinity

    /// Queue admission can be instant while the actual socket is congested.
    /// Sample live wire age with a real backlog; cumulative maxima and a lone
    /// paused/seek frame are not evidence of current sustained pressure.
    mutating func observeTransport(now: Double, pendingAge: Double, queuedFrames: Int) -> Int? {
        guard now.isFinite, pendingAge.isFinite else { return nil }
        if previousPressureSample < 0 || now - previousPressureSample > 0.75 || now < previousPressureSample {
            pressureSince = -1
        }
        previousPressureSample = now
        guard pendingAge >= 0.25, queuedFrames >= 4 else { pressureSince = -1; return nil }
        if pressureSince < 0 { pressureSince = now }
        guard now - pressureSince >= 0.25, now - lastPressureReduction >= 1, bitrate > 16_000_000 else { return nil }
        bitrate = bitrate == 32_000_000 ? 24_000_000 : 16_000_000
        lastPressureReduction = now; pressureSince = now
        return bitrate
    }
    mutating func observe(now: Double, queueAge: Double, writeWait: Double) -> Int? {
        guard now.isFinite, queueAge.isFinite, writeWait.isFinite else { return nil }
        if windowStart < 0 || now - previous > 1 { windowStart = now; samples = 0; late = 0 }
        previous = now; samples += 1
        if queueAge >= 0.120 && writeWait >= 0.008 { late += 1 }
        stalled = writeWait >= 0.3 ? stalled + 1 : 0
        guard now - windowStart >= 2 || stalled >= 3 else { return nil }
        let reduce = stalled >= 3 || (samples >= 30 && late >= max(6, samples / 5))
        windowStart = now; samples = 0; late = 0; stalled = 0
        guard reduce, bitrate != 16_000_000 else { return nil }
        bitrate = bitrate == 32_000_000 ? 24_000_000 : 16_000_000
        return bitrate
    }
}
