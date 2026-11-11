import Foundation

/// Invoked only by --self-test. The host already opened the bundled synthetic video,
/// muted playback and isolated its preferences/account/history from the user's data.
@MainActor
enum MacSoundValidation {
    private enum Failure: Error { case check(String) }
    static func run(_ model: MacPlayerModel) async throws -> [String: Double] {
        guard let playback = model.playback else { throw Failure.check("missing audio host") }
        var reference: [Float]?, maxDifference = 0.0
        let profiles = [SoundProfile(), SoundProfile(mode: .cinema),
            SoundProfile(mode: .dialogue), SoundProfile(mode: .night, strength: 0.3, nightReduction: 0.7, nightBoost: 0.3), SoundProfile()]
        defer { playback.onProcessedAudioPCM = nil; model.soundComparison = .off; model.sound = SoundProfile() }
        for profile in profiles {
            model.pause(); model.sound = profile
            var captured = [Float](repeating: 0, count: 48_000), seen = [Bool](repeating: false, count: 24_000)
            playback.onProcessedAudioPCM = { pcm, time in
                let first = Int((time * 48_000).rounded()) - 72_000
                for i in 0..<(pcm.count / 2) {
                    let to = first + i
                    if to >= 0 && to < 24_000 {
                        captured[to * 2] = pcm[i * 2]; captured[to * 2 + 1] = pcm[i * 2 + 1]; seen[to] = true
                    }
                }
            }
            await model.seek(to: 1); model.play()
            let deadline = ProcessInfo.processInfo.systemUptime + 6
            while (!seen.allSatisfy({ $0 }) || playback.currentTimeSeconds < 1.3), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            model.pause()
            guard seen.allSatisfy({ $0 }), model.playback === playback, playback.lastError == nil,
                  captured.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw Failure.check("sound output/clock failed") }
            if reference == nil { reference = captured }
            let energy = reference!.reduce(0.0) { $0 + Double($1) * Double($1) }
            let difference = sqrt(zip(captured, reference!).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) } / max(1e-12, energy))
            if profile.mode == .original {
                guard difference < 0.00001 else { throw Failure.check("original not restored") }
            } else {
                guard difference > 0.02 else { throw Failure.check("preset did not reach audio output") }
                maxDifference = max(maxDifference, difference)
            }
        }
        playback.onProcessedAudioPCM = nil
        model.selectSoundTarget(.headphones)
        model.sound = SoundProfile(mode: .night, nightReduction: 0.2, nightBoost: 0.8)
        let saved = model.sound
        model.selectSoundTarget(.tv); model.selectSoundTarget(.headphones)
        guard model.sound == saved else { throw Failure.check("output profile not restored") }
        model.selectSoundTarget(.standard)
        model.sound = SoundProfile(mode: .cinema)
        model.soundComparison = .processed; model.play()
        try await Task.sleep(for: .milliseconds(400))
        let time = playback.currentTimeSeconds
        model.soundComparison = .original
        try await Task.sleep(for: .milliseconds(400))
        guard playback.currentTimeSeconds > time + 0.2, model.playback === playback else { throw Failure.check("comparison restarted or stalled audio") }
        model.pause(); model.soundComparison = .off; model.sound = SoundProfile()
        for offset in [-110, 110, 0, -1, 1, 0] {
            model.setAudioSyncHundredths(offset)
            try await Task.sleep(for: .milliseconds(300))
            await model.seek(to: 1.5)
            guard playback.activeAudioSyncSeconds == Double(offset) / 100 else { throw Failure.check("manual audio offset not applied") }
            model.play()
            try await Task.sleep(for: .milliseconds(250))
            model.pause()
            guard playback.currentTimeSeconds > 1.6, playback.lastError == nil,
                  playback.audioGapFrames == 0 else { throw Failure.check("manual audio seek stalled") }
        }
        model.play() // Preserve the existing harness contract: its next toggle pauses.
        return ["manualAudioOffsetSeekChecks": 6, "soundProfilesVerified": 5, "soundDeviceRestoreVerified": 1, "soundComparisonClockVerified": 1,
                "soundMaximumRelativePCMDifference": maxDifference]
    }
}
