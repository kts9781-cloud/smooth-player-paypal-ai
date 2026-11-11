import Foundation

public struct SubtitleSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var scale = 1.0
    public var outline = true
    public var offsetSeconds = 0.0
    public var rate = 1.0
    public static let rates = [1.0, 25.0 / 23.976, 23.976 / 25.0]

    public var sanitized: Self {
        var value = self
        value.scale = scale.isFinite ? min(2, max(0.5, scale)) : 1
        value.offsetSeconds = offsetSeconds.isFinite ? min(3_600, max(-3_600, offsetSeconds)) : 0
        value.rate = Self.rates.contains(rate) ? rate : 1
        return value
    }
    public func subtitleTime(for playbackTime: Double) -> Double {
        let safe = sanitized
        return playbackTime * safe.rate + safe.offsetSeconds
    }
    public mutating func align(cueStart: Double, playbackTime: Double) {
        guard cueStart.isFinite, playbackTime.isFinite else { return }
        offsetSeconds = cueStart - playbackTime * sanitized.rate
        self = sanitized
    }
}
