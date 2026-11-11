import Foundation

/// Rate of completed transport writes. It does not measure the TV panel's refresh rate.
struct TVFrameRateMeter {
    private var previousCount: Int64?
    private var previousTime: Double?
    private(set) var framesPerSecond: Double?

    mutating func reset() { self = Self() }

    mutating func sample(count: Int64, now: Double, playing: Bool) {
        guard playing, count >= 0, now.isFinite else { reset(); return }
        guard let before = previousCount, let time = previousTime,
              count >= before, now >= time else {
            previousCount = count; previousTime = now; framesPerSecond = nil
            return
        }
        let elapsed = now - time
        guard elapsed >= 1 else { return }
        framesPerSecond = Double(count - before) / elapsed
        previousCount = count; previousTime = now
    }
}
