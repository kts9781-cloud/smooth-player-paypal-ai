import Foundation

enum PlaybackTimelineMapping {
    static func target(x: Double, width: Double, duration: Double) -> Double? {
        guard x.isFinite, width.isFinite, width > 16, duration.isFinite, duration > 0 else { return nil }
        return min(1, max(0, (x - 8) / (width - 16))) * duration
    }
}

enum PlayerGestureCommand: Equatable {
    case seek(Double), brightness(Double), volume(Double)
}

enum PlayerGestureMapping {
    static func command(startX: Double, width: Double, height: Double, dx: Double, dy: Double,
                        startTime: Double, duration: Double, brightness: Double, volume: Double, horizontal: Bool) -> PlayerGestureCommand {
        if horizontal { return .seek(min(max(0, duration), max(0, startTime + dx / 160 * 10))) }
        let delta = -dy / max(1, height)
        return startX < width / 2 ? .brightness(min(1, max(0.05, brightness + delta))) : .volume(min(1, max(0, volume + delta)))
    }
}
