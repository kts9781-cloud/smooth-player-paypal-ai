import Foundation

/// Container timestamps can be rounded to a codec packet grid as well as to
/// milliseconds. Keep small bounded timestamp jitter out of the PCM waveform.
public enum AudioTimestampAlignment {
    public static let timestampToleranceSeconds = 0.002

    public static func correctionFrames(actualTime: Double, expectedTime: Double,
                                        sampleRate: Int = 48_000, packetFrames: Int = 0) -> Int? {
        guard actualTime.isFinite, expectedTime.isFinite, sampleRate > 0, packetFrames >= 0 else { return nil }
        let delta = actualTime - expectedTime
        guard abs(delta) <= 10 else { return nil }
        // Some 44.1 kHz AAC MKVs stamp packets on a 48 kHz AAC grid: ~21/43 ms
        // timestamp steps describe continuous ~23.22 ms PCM blocks. The observed
        // error oscillates by ~22 ms peak-to-peak; a 2 ms-only rule cuts valid audio
        // and inserts silence repeatedly. Allow one decoded packet, capped at 25 ms
        // so large PCM blocks never hide real long gaps or accumulated clock drift.
        let tolerance = max(timestampToleranceSeconds, min(0.025, Double(packetFrames) / Double(sampleRate)))
        if abs(delta) <= tolerance { return 0 }
        return Int((delta * Double(sampleRate)).rounded())
    }
}
