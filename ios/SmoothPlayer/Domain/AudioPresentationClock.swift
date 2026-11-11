import Foundation

/// Project one audio sample/host timestamp onto the current host clock.
/// Output-device latency belongs to the presentation clock, not the decode queue.
public enum AudioPresentationClock {
    public static func seconds(renderedFrames: Int64, scheduledFrames: Int64,
                               sampleRate: Double, renderHostSeconds: Double?,
                               nowSeconds: Double, running: Bool,
                               presentationDelaySeconds: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        var elapsed = 0.0
        if running, let host = renderHostSeconds, host.isFinite, nowSeconds.isFinite {
            let delta = nowSeconds - host
            // A valid render timestamp can be ahead of or behind the host clock
            // by more than one display/audio callback. Truncating it to 100 ms
            // changes the clock mapping, especially on buffered output routes.
            if delta.isFinite { elapsed = delta }
        }
        let delay = presentationDelaySeconds.isFinite ? max(0, presentationDelaySeconds) : 0
        let rendered = Double(max(0, renderedFrames)) / sampleRate
        let queuedEnd = Double(max(0, scheduledFrames)) / sampleRate
        // Delay is applied before the queue/EOF bound so the last audible PCM drains.
        return min(queuedEnd, max(0, rendered + elapsed - delay))
    }
}


/// Map the audio-master timeline to the display's upcoming presentation instant.
/// Sampling at draw invocation instead makes callback/drawable-wait jitter select
/// alternating old/new slots even when the producer has every frame ready.
public enum VideoPresentationClock {
    public struct Sample: Sendable {
        public let mediaTime: Double
        public let hostTime: Double?
        public let observedMediaTime: Double
    }
    public static func sample(mediaTime: Double, sampledHostTime: Double,
                              targetHostTime: Double?, interval: Double, playing: Bool,
                              advanceLateTarget: Bool = true) -> Sample {
        guard playing, mediaTime.isFinite, sampledHostTime.isFinite,
              let targetHostTime, targetHostTime.isFinite,
              interval.isFinite, interval > 0, interval <= 0.1,
              abs(targetHostTime - sampledHostTime) <= 0.25 else {
            return Sample(mediaTime: mediaTime, hostTime: nil, observedMediaTime: mediaTime)
        }
        // A late drawable must not schedule a stale picture for an already passed
        // refresh. Move to the next point on the same display grid, not an arbitrary now.
        var target = targetHostTime
        // Remote capture uses the just-completed refresh, without the local
        // drawable's future lead. Keep that stable grid despite callback jitter.
        if advanceLateTarget, target < sampledHostTime { target += ceil((sampledHostTime - target) / interval) * interval }
        return Sample(mediaTime: mediaTime + target - sampledHostTime, hostTime: target, observedMediaTime: mediaTime)
    }
}
