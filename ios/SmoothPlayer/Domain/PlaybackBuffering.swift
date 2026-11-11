import Foundation

/// A short refill is not a visible loading event. Require a continuous wait with
/// no media-clock progress; pause, seek, recovery and a new item start fresh.
struct PlaybackBufferingNotice {
    private var waitingSince: Double?
    private var lastPosition: Double?

    mutating func update(now: Double, position: Double, waiting: Bool, active: Bool) -> Bool {
        guard active, waiting, now.isFinite, position.isFinite else {
            waitingSince = nil
            lastPosition = nil
            return false
        }
        if waitingSince == nil || now < waitingSince! || lastPosition.map({ abs(position - $0) > 0.001 }) == true {
            waitingSince = now
        }
        lastPosition = position
        return now - (waitingSince ?? now) >= 0.75
    }
}

/// Keep the low-water mark below the resume target even when high-resolution
/// decoded frames leave room for only a very short read-ahead window.
struct PlaybackAudioBufferingPolicy {
    let resumeFrames: Int64
    let pauseBelowSeconds: Double

    init(videoBufferSeconds: Double) {
        let lead = videoBufferSeconds.isFinite ? max(0, videoBufferSeconds) : 0
        resumeFrames = max(1, Int64(min(0.2, lead * 0.75) * 48_000))
        pauseBelowSeconds = min(0.05, Double(resumeFrames) / 48_000 * 0.25)
    }
}
