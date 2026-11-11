import Foundation

/// Bounded history of the app's processed 48 kHz stereo PCM, keyed to media time.
/// Like Android PlaybackPcm, preserve sample order across <=30 ms scheduling jitter.
final class AirPlayPCM: @unchecked Sendable {
    // Interleaved containers can queue audio ahead of the video decode target.
    // Real playback leads reached 1.46 s: a 1 s ring replaced current audio with
    // silence. Four seconds retains that preroll with headroom (1.5 MiB), without
    // delaying reads or moving the audio/video clock to the newest sample.
    static let capacityFrames = 4 * 48_000
    private let lock = NSLock()
    private var samples = [Float](repeating: 0, count: capacityFrames * 2)
    private var end: Int64?
    private var cursor: Int64?
    private var generation = 0
    // Cumulative for this ring's lifetime, including across explicit seek resets.
    // Availability bounds are metadata only; they do not change the read policy.
    private var firstAvailable: Int64?
    private var readCount: Int64 = 0, playingReads: Int64 = 0, silentReads: Int64 = 0
    private var missingFrames: Int64 = 0, emptyReads: Int64 = 0, aheadReads: Int64 = 0, overwrittenFrames: Int64 = 0
    private var reanchors: Int64 = 0, forwardSkippedFrames: Int64 = 0, backwardRepeatedFrames: Int64 = 0
    private var appendDiscontinuities: Int64 = 0, explicitResets: Int64 = 0, restartedReads: Int64 = 0
    private var appendedFrames: Int64 = 0, maximumCursorDrift: Int64 = 0
    private var minimumLead: Int64?, maximumLead: Int64?, lastLead: Int64 = 0

    var diagnostics: [String: Double] {
        lock.lock(); defer { lock.unlock() }
        return ["capacityFrames": Double(Self.capacityFrames), "generation": Double(generation), "reads": Double(readCount),
            "playingReads": Double(playingReads), "intentionalSilentReads": Double(silentReads),
            "missingFrames": Double(missingFrames), "emptyReads": Double(emptyReads),
            "aheadReads": Double(aheadReads), "overwrittenFrames": Double(overwrittenFrames),
            "reanchors": Double(reanchors), "forwardSkippedFrames": Double(forwardSkippedFrames),
            "backwardRepeatedFrames": Double(backwardRepeatedFrames),
            "appendDiscontinuities": Double(appendDiscontinuities), "explicitResets": Double(explicitResets),
            "restartedReads": Double(restartedReads), "appendedFrames": Double(appendedFrames),
            "maximumCursorDriftFrames": Double(maximumCursorDrift),
            "minimumLeadFrames": Double(minimumLead ?? 0), "maximumLeadFrames": Double(maximumLead ?? 0),
            "lastLeadFrames": Double(lastLead)]
    }
    func append(_ pcm: [Float], time: Double) {
        guard time.isFinite, abs(time) < 1e10, !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 960_000 else { return }
        lock.lock(); defer { lock.unlock() }
        var first = Int64((time * 48_000).rounded())
        if let end {
            if abs(first - end) <= 96 { first = end }
            else {
                cursor = nil; samples = Array(repeating: 0, count: Self.capacityFrames * 2); generation += 1
                appendDiscontinuities += 1; firstAvailable = first
            }
        }
        if firstAvailable == nil { firstAvailable = first }
        for i in 0..<(pcm.count / 2) {
            let frame = first + Int64(i)
            let capacity = Int64(Self.capacityFrames)
            let at = Int((frame % capacity + capacity) % capacity) * 2
            samples[at] = pcm[i * 2].isFinite ? pcm[i * 2] : 0
            samples[at + 1] = pcm[i * 2 + 1].isFinite ? pcm[i * 2 + 1] : 0
        }
        end = first + Int64(pcm.count / 2)
        appendedFrames += Int64(pcm.count / 2)
        firstAvailable = max(firstAvailable ?? first, first + Int64(pcm.count / 2) - Int64(Self.capacityFrames))
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        end = nil; cursor = nil; generation += 1; samples = Array(repeating: 0, count: Self.capacityFrames * 2)
        firstAvailable = nil; explicitResets += 1
    }
    /// Pause/resume and clock invalidation discard the read cursor, not decoder preroll.
    func restartRead() { lock.lock(); cursor = nil; restartedReads += 1; lock.unlock() }
    func read(time: Double, playing: Bool) -> (samples: [Float], generation: Int) {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        var output = [Float](repeating: 0, count: 960)
        guard playing else { silentReads += 1; cursor = nil; return (output, generation) }
        playingReads += 1
        guard time.isFinite, abs(time) < 1e10, let end else {
            missingFrames += 480; emptyReads += 1; cursor = nil; return (output, generation)
        }
        let played = Int64((time * 48_000).rounded())
        lastLead = end - played
        minimumLead = min(minimumLead ?? lastLead, lastLead); maximumLead = max(maximumLead ?? lastLead, lastLead)
        guard played < end else {
            missingFrames += 480; aheadReads += 1; cursor = nil; return (output, generation)
        }
        if let cursor {
            let drift = played - cursor
            maximumCursorDrift = max(maximumCursorDrift, abs(drift))
            if abs(drift) > 1440 {
                reanchors += 1
                if drift > 0 { forwardSkippedFrames += drift } else { backwardRepeatedFrames -= drift }
            }
        }
        let start = cursor.flatMap { abs($0 - played) <= 1440 ? $0 : nil } ?? played
        for i in 0..<480 {
            let frame = start + Int64(i)
            if frame < (firstAvailable ?? end) || frame >= end {
                missingFrames += 1
                if frame < end - Int64(Self.capacityFrames) { overwrittenFrames += 1 }
            }
            if frame >= (firstAvailable ?? end) && frame < end {
                let capacity = Int64(Self.capacityFrames)
                let at = Int((frame % capacity + capacity) % capacity) * 2
                output[i * 2] = samples[at]; output[i * 2 + 1] = samples[at + 1]
            }
        }
        cursor = start + 480
        return (output, generation)
    }
}
