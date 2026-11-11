import AVFoundation
import Foundation
import CoreVideo
import QuartzCore

/// Progressive decode with a bounded video window and PCM audio master. No full-file remux or
/// transcode is needed: the same decoder accepts local files and random-access NAS byte streams.
@MainActor
final class FFmpegPlayback {
    let decoder = FFmpegDecoder()
    private var audioDecoder: FFmpegDecoder?
    private var audioPump: Task<Void, Never>?
    private var videoReachedEOF = false
    private var audioReachedEOF = false
    private var separateVideoDuration: Double?
    private var separateTailSilenceFrames: Int64 = 0
    var hasSeparateAudio: Bool { audioDecoder != nil }
    let frames = FFmpegFrameBuffer()
    private(set) var info: FFmpegMediaInfo?
    private(set) var isPlaying = false
    private(set) var decodedVideoFrames = 0
    private(set) var decodedAudioFrames = 0
    private(set) var isBuffering = false
    private(set) var containsHDR = false
    private(set) var hardwareDecodedVideoFrames = 0
    private(set) var isHardwareDecoding = false
    private(set) var hardwareRecoveryAttempts = 0
    private(set) var softwareRecoveryAttempts = 0
    private var recovering = false
    private var requestedPlay = false
    private var seeking = false
    var playbackRequested: Bool { requestedPlay }
    #if DEBUG || SMOOTH_TEST_HOST
    var beforeSeekResumeForTesting: (() async -> Void)?
    #endif
    private(set) var rebufferCount = 0
    private(set) var audioGapFrames: Int64 = 0
    private(set) var insertedAudioSilenceFrames: Int64 = 0
    private(set) var droppedAudioOverlapFrames: Int64 = 0
    private(set) var toleratedAudioTimestampJitterEvents = 0
    private(set) var latestDiagnostics: [String: Double] = [:]
    private var monitor: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    #if (DEBUG || SMOOTH_PLAYBACK_DIAGNOSTICS) && !os(macOS)
    private var diagnosticHistory: [[String: Double]] = []
    private let diagnosticSessionID = UUID().uuidString
    #endif
    private var actualVideoFrameBytes = 0
    private var bufferingPosition = 0.0
    private(set) var lastError: String?
    private var remoteFailure: HTTPSRangeError?
    var onFailure: ((String) -> Void)?
    var onEnded: (() -> Void)?
    var onSubtitlePacket: ((NativeSubtitlePacket) async -> Void)?
    /// Post-DSP stereo Float32 PCM and its media start time; consumers must enqueue bounded work.
    var onProcessedAudioPCM: (([Float], Double) -> Void)?
    var effectDiagnostics: (() -> [String: Double])?
    private let engine = AVAudioEngine()
    private let audio = AVAudioPlayerNode()
    private let audioProcessor = AudioProcessor()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    #if os(macOS)
    /// Match notifications to this engine; the Mac host rebuilds only its own
    /// stopped graph after an output-device change, preserving the media position.
    var audioConfigurationNotificationObject: AVAudioEngine { engine }
    #endif
    private var pump: Task<Void, Never>?
    private var generation = 0
    private var closed = false
    private var ended = false
    private var reachedEOF = false
    var requestedAudioSyncHundredths = 0
    private(set) var activeAudioSyncSeconds = 0.0
    private var manualAudioCursor = false
    private var inputURL: URL?
    private var inputStream: (any MediaByteStream)?
    private var inputCacheMegabytes = 32
    // The primary decoder owns the transport; this cursor only borrows random-access reads.
    private final class BorrowedStream: MediaByteStream, @unchecked Sendable {
        let base: any MediaByteStream
        init(_ base: any MediaByteStream) { self.base = base }
        var size: Int64 { base.size }
        func read(offset: Int64, count: Int) async throws -> Data { try await base.read(offset: offset, count: count) }
        func close() async {}
    }
    private func prepareAudioSync() async throws {
        activeAudioSyncSeconds = usesRemoteAudioClock ? 0 : AudioSyncAdjustment.seconds(requestedAudioSyncHundredths)
        if manualAudioCursor, activeAudioSyncSeconds == 0 {
            let cursor = audioDecoder
            audioDecoder = nil; manualAudioCursor = false
            cursor?.cancel(); await cursor?.close()
        }
        if info?.hasAudio == true, audioDecoder == nil, activeAudioSyncSeconds != 0 {
            let cursor = FFmpegDecoder()
            audioDecoder = cursor; manualAudioCursor = true
            _ = try await cursor.open(url: inputURL, stream: inputStream.map { BorrowedStream($0) },
                cacheMegabytes: inputCacheMegabytes, requireVideo: false, audioOnly: true)
            updateDecoderSound()
        }
    }
    private var audioOrigin: Double?
    private var audioScheduledFrames: Int64 = 0
    private var lastAudioRenderedFrames: Int64 = 0
    private var seekTarget = 0.0
    private var pausedTime = 0.0
    private var pausedPresentationTime = 0.0
    private var hostOrigin = 0.0
    private var videoEnd = 0.0
    private var presentationFrames: [DecodedVideoFrame] = []
    private var prepared = false
    /// Our app-owned TV sender has its own PCM clock. Its video must not inherit
    /// the latency of a muted local Bluetooth/speaker output.
    var usesRemoteAudioClock = false
    #if DEBUG || SMOOTH_TEST_HOST
    var outputLatencyForTesting: Double?
    #endif
    private let openedAt = Date()
    var duration: Double { info?.duration ?? 0 }
    var playbackVolume: Float {
        get { audio.volume }
        set { audio.volume = newValue.isFinite ? min(1, max(0, newValue)) : 1 }
    }
    private var soundProfile = SoundProfile()
    var soundComparison: SoundComparison = .off { didSet { audioProcessor.comparison = soundComparison; updateDecoderSound() } }
    func setSoundProfile(_ profile: SoundProfile) {
        soundProfile = profile.sanitized(); audioProcessor.configure(soundProfile); updateDecoderSound()
    }
    private func updateDecoderSound() {
        let focus: Float = soundProfile.mode == .dialogue ? soundProfile.strength : soundProfile.mode == .night ? soundProfile.strength * 0.35 : 0
        decoder.setSoundOptions(focus: focus, reference: soundComparison != .off)
        audioDecoder?.setSoundOptions(focus: focus, reference: soundComparison != .off)
    }
    var isMuted: Bool {
        get { info?.hasAudio == true && audio.volume == 0 }
        set { if info?.hasAudio == true { audio.volume = newValue ? 0 : 1 } }
    }
    private var videoBufferSeconds: Double {
        guard let info else { return 0.2 }
        let frameBytes = actualVideoFrameBytes > 0 ? Double(actualVideoFrameBytes) : Double(info.width) * Double(info.height) * 4
        let fps = max(1, info.fps)
        let capacity = floor(256 * 1024 * 1024 / max(1, frameBytes))
        let retainedPastFrames = ceil((presentationDelaySeconds + max(0.05, 1 / fps)) * fps)
        // Reserve past frames, the decoder's new frame, and one time-bound overshoot before
        // deriving future lead; counting only future pixels understated the retained peak.
        let futureFrames = max(1, capacity - retainedPastFrames - 2)
        let maximumLead = info.width * info.height > 1_920 * 1_080 ? 0.4 : 0.8
        return min(maximumLead, futureFrames / fps)
    }
    private var audioBufferingPolicy: PlaybackAudioBufferingPolicy {
        PlaybackAudioBufferingPolicy(videoBufferSeconds: videoBufferSeconds)
    }
    private var audioPrerollFrames: Int64 { audioBufferingPolicy.resumeFrames }
    var audioRenderedFrames: Int64 { audioClockSnapshot().frames }
    private func audioClockSnapshot() -> (frames: Int64, timelineFrames: Int64, hostTime: UInt64?) {
        guard info?.hasAudio == true else { return (0, 0, nil) }
        guard let render = audio.lastRenderTime, let time = audio.playerTime(forNodeTime: render) else {
            return (lastAudioRenderedFrames, lastAudioRenderedFrames, nil)
        }
        let contentFrames = max(0, time.sampleTime - audioGapFrames)
        // Silence after EOF is the downstream drain, not an underrun. Keep that
        // timeline advancing until the last PCM reaches the selected output.
        if !reachedEOF, contentFrames > audioScheduledFrames { audioGapFrames += contentFrames - audioScheduledFrames }
        lastAudioRenderedFrames = max(lastAudioRenderedFrames, min(audioScheduledFrames, contentFrames))
        return (lastAudioRenderedFrames, reachedEOF ? contentFrames : lastAudioRenderedFrames,
                render.isHostTimeValid ? render.hostTime : nil)
    }
    private func audioTimeSeconds(presentationDelay: Double, hostTime: Double = CACurrentMediaTime()) -> Double {
        guard let audioOrigin else { return seekTarget }
        let snapshot = audioClockSnapshot()
        let elapsedPosition = AudioPresentationClock.seconds(
            renderedFrames: snapshot.timelineFrames, scheduledFrames: audioScheduledFrames,
            sampleRate: format.sampleRate,
            renderHostSeconds: snapshot.hostTime.map { AVAudioTime.seconds(forHostTime: $0) },
            nowSeconds: hostTime, running: audio.isPlaying && engine.isRunning,
            presentationDelaySeconds: presentationDelay)
        return audioOrigin + elapsedPosition
    }
    var currentTimeSeconds: Double {
        guard prepared else { return seekTarget }
        if !isPlaying { return pausedTime }
        if isBuffering { return bufferingPosition }
        if info?.hasAudio == true {
            // Audio rendering advances in blocks (often 512 samples), while a 60/120 Hz
            // display needs a continuous clock between those callbacks. Extrapolate from
            // that block's host timestamp instead of repeating/dropping pictures at each block.
            return max(pausedTime, audioTimeSeconds(presentationDelay: 0))
        }
        return isPlaying ? min(videoEnd, pausedTime + CACurrentMediaTime() - hostOrigin) : pausedTime
    }
    /// lastRenderTime measures PCM render progress, not the time that PCM leaves
    /// the selected output. Use the node's downstream latency once (do not add
    /// AVAudioSession.outputLatency a second time). Keep decoding/backpressure
    /// and app-owned TV transport on the original render clock.
    var presentationDelaySeconds: Double {
        guard info?.hasAudio == true, !usesRemoteAudioClock else { return 0 }
        #if DEBUG || SMOOTH_TEST_HOST
        let delay = outputLatencyForTesting ?? audio.outputPresentationLatency
        #else
        let delay = audio.outputPresentationLatency
        #endif
        return delay.isFinite && delay > 0 ? delay : 0
    }
    var presentationTimeSeconds: Double { presentationTime(atHostTime: CACurrentMediaTime()) }
    /// Query the audio anchor at the intended display instant. Extrapolate before
    /// clamping startup/EOF, so a waiting audio start is not mistaken for advancing
    /// media and output-device latency remains applied exactly once.
    func presentationTime(atHostTime requestedHostTime: Double) -> Double {
        guard prepared else { return seekTarget }
        let hostTime = requestedHostTime.isFinite ? requestedHostTime : CACurrentMediaTime()
        let localAudio = info?.hasAudio == true && !usesRemoteAudioClock
        if !isPlaying { return localAudio ? pausedPresentationTime : pausedTime }
        if isBuffering { return localAudio ? max(seekTarget, bufferingPosition - presentationDelaySeconds) : bufferingPosition }
        if info?.hasAudio == true {
            return max(localAudio ? pausedPresentationTime : pausedTime,
                audioTimeSeconds(presentationDelay: localAudio ? presentationDelaySeconds : 0, hostTime: hostTime))
        }
        return min(videoEnd, pausedTime + hostTime - hostOrigin)
    }
    var transform: CGAffineTransform {
        // FFmpeg reports clockwise display rotation; Core Image uses a Y-up coordinate space.
        let angle = -(info?.rotation ?? 0) * .pi / 180
        let aspect = info?.sampleAspectRatio ?? 1
        return CGAffineTransform(scaleX: aspect > 0 ? aspect : 1, y: 1).rotated(by: angle)
    }
    func open(url: URL?, stream: (any MediaByteStream)?, at position: Double, networkBufferMegabytes: Int = 32,
              audioURL: URL? = nil, audioStream: (any MediaByteStream)? = nil) async throws {
        do {
            inputURL = url; inputStream = stream; inputCacheMegabytes = networkBufferMegabytes
            info = try await decoder.open(url: url, stream: stream, cacheMegabytes: networkBufferMegabytes, prefetch: true)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if audioURL != nil || audioStream != nil {
                let separate = FFmpegDecoder()
                audioDecoder = separate // close() can cancel an in-flight open.
                updateDecoderSound()
                let audioInfo = try await separate.open(url: audioURL, stream: audioStream,
                    cacheMegabytes: 16, requireVideo: false, prefetch: true)
                guard let video = info, !video.hasAudio else { throw FFmpegPlaybackError.invalidFrame }
                guard video.duration.isFinite, audioInfo.duration.isFinite,
                      video.duration > 0, audioInfo.duration > 0,
                      abs(video.duration - audioInfo.duration) <= 2 else { throw FFmpegPlaybackError.invalidFrame }
                // Only matched public YouTube tracks are paired. Each native
                // decoder normalizes its own container start; reject offsets
                // beyond 50 ms rather than silently losing their A/V alignment.
                // This is a fail-safe, not general separate-track offset support.
                guard video.timelineOrigin.isFinite, audioInfo.timelineOrigin.isFinite,
                      abs(video.timelineOrigin - audioInfo.timelineOrigin) <= 0.050 else { throw FFmpegPlaybackError.invalidFrame }
                separateVideoDuration = video.duration > 0 ? video.duration : nil
                info = FFmpegMediaInfo(duration: video.duration, timelineOrigin: video.timelineOrigin, fps: video.fps,
                    width: video.width, height: video.height, hasAudio: true, rotation: video.rotation,
                    sampleAspectRatio: video.sampleAspectRatio, isHDR: video.isHDR,
                    videoCodec: video.videoCodec, audioCodec: audioInfo.audioCodec)
            }
            try await prepareAudioSync()
            containsHDR = info?.isHDR == true
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if info?.hasAudio == true {
                engine.attach(audio)
                engine.connect(audio, to: engine.mainMixerNode, format: format)
                engine.prepare()
                try engine.start()
            }
            seekTarget = max(0, position)
            pausedTime = seekTarget
            pausedPresentationTime = seekTarget
            if seekTarget > 0 {
                try await decoder.seek(to: seekTarget)
            }
            if let audioDecoder { try await audioDecoder.seek(to: max(0, seekTarget - activeAudioSyncSeconds)) }
            prepared = true
            startPump()
            try await waitForPreroll()
        } catch {
            generation += 1
            pump?.cancel(); pump = nil
            audioPump?.cancel(); audioPump = nil
            audio.stop(); engine.stop()
            await decoder.close()
            await audioDecoder?.close()
            // One decoder may fail before the other input is adopted.
            await stream?.close(); await audioStream?.close()
            throw error
        }
    }
    private func waitForPreroll() async throws {
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if let remoteFailure { throw remoteFailure }
            if let lastError { throw NSError(domain: "SmoothPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: lastError]) }
            if decodedVideoFrames > 0, (info?.hasAudio != true || audioScheduledFrames >= audioPrerollFrames || reachedEOF) { return }
            if reachedEOF { throw FFmpegPlaybackError.noVideo }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FFmpegPlaybackError.decode(-110)
    }
    func play() {
        requestedPlay = true
        guard prepared, !closed, !ended, !recovering, !seeking else { return }
        if !engine.isRunning, info?.hasAudio == true { try? engine.start() }
        hostOrigin = CACurrentMediaTime()
        isPlaying = true
        if info?.hasAudio == true { audio.play() }
        startPump()
        startMonitor()
    }
    func pause() {
        requestedPlay = false
        pausedPresentationTime = presentationTimeSeconds
        pausedTime = currentTimeSeconds
        if info?.hasAudio == true { audio.pause() }
        isPlaying = false
        isBuffering = false
        monitor?.cancel(); monitor = nil
        diagnosticsTask?.cancel(); diagnosticsTask = nil
    }
    func seek(to seconds: Double) async throws {
        guard !closed, seconds.isFinite else { return }
        // A user request during decoder recovery must wait, rather than silently disappearing.
        while recovering, !closed { try await Task.sleep(for: .milliseconds(10)) }
        guard !closed else { return }
        let resume = requestedPlay
        pause()
        requestedPlay = resume
        seeking = true
        defer { seeking = false }
        generation += 1
        pump?.cancel(); pump = nil
        audioPump?.cancel(); audioPump = nil
        if info?.hasAudio == true { audio.stop() }
        audioProcessor.reset()
        audioOrigin = nil; audioScheduledFrames = 0; lastAudioRenderedFrames = 0; audioGapFrames = 0
        seekTarget = max(0, duration > 0 ? min(seconds, max(0, duration - 0.001)) : seconds)
        pausedTime = seekTarget
        pausedPresentationTime = seekTarget
        videoEnd = seekTarget
        decodedVideoFrames = 0; decodedAudioFrames = 0
        ended = false; reachedEOF = false; lastError = nil; remoteFailure = nil
        videoReachedEOF = false; audioReachedEOF = false
        separateTailSilenceFrames = 0
        presentationFrames.removeAll()
        await frames.reset()
        try await prepareAudioSync()
        try await decoder.seek(to: seekTarget)
        try await audioDecoder?.seek(to: max(0, seekTarget - activeAudioSyncSeconds))
        guard !closed else { return }
        startPump()
        try await waitForPreroll()
        #if DEBUG || SMOOTH_TEST_HOST
        await beforeSeekResumeForTesting?()
        #endif
        // A remote pause received during seek/preroll must win over the old
        // playing state. A new play request waits until this reset is complete.
        seeking = false
        if requestedPlay, !closed { play() }
    }
    func close() {
        guard !closed else { return }
        pause(); closed = true; generation += 1
        pump?.cancel(); pump = nil
        audioPump?.cancel(); audioPump = nil
        if info?.hasAudio == true { audio.stop() }; engine.stop()
        presentationFrames.removeAll()
        decoder.cancel()
        audioDecoder?.cancel()
        Task { await decoder.close(); await audioDecoder?.close(); await frames.finish() }
    }
    func frameForPresentation(at time: Double) -> DecodedVideoFrame? {
        while presentationFrames.count > 1, presentationFrames[1].time <= time + 0.002 {
            presentationFrames.removeFirst()
        }
        return presentationFrames.first
    }

    var queuedAudioSeconds: Double { Double(max(0, audioScheduledFrames - audioRenderedFrames)) / 48_000 }

    func performanceDiagnostics() async -> [String: Double] {
        var values = await decoder.diagnosticMetrics()
        values.merge(remoteAudioDiagnostics) { _, value in value }
        values["decodedVideoFrames"] = Double(decodedVideoFrames)
        values["hardwareDecodedVideoFrames"] = Double(hardwareDecodedVideoFrames)
        values["decodedSourcePeakBytes"] = Double(await frames.peakBufferedByteCount)
        return values
    }

    /// Numeric technical state only. No file names, server addresses, credentials,
    /// subtitles, waveform samples or decoded pictures are included.
    var remoteAudioDiagnostics: [String: Double] {
        let mediaTime = currentTimeSeconds
        let rendered = lastAudioRenderedFrames
        #if os(macOS)
        let outputSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let outputLatency = engine.outputNode.outputPresentationLatency
        #else
        let audioSession = AVAudioSession.sharedInstance()
        let outputSampleRate = audioSession.sampleRate
        let outputLatency = audioSession.outputLatency
        #endif
        let nodeTime = audio.lastRenderTime.flatMap { audio.playerTime(forNodeTime: $0) }
        return [
            "currentMediaSeconds": mediaTime,
            "isPlaying": isPlaying ? 1 : 0, "isBuffering": isBuffering ? 1 : 0,
            "hasAudio": info?.hasAudio == true ? 1 : 0,
            "audioPlayerVolume": Double(audio.volume),
            "audioMixerVolume": Double(engine.mainMixerNode.outputVolume),
            "audioScheduledFrames": Double(audioScheduledFrames), "audioRenderedFrames": Double(rendered),
            "queuedAudioSeconds": Double(max(0, audioScheduledFrames - rendered)) / 48_000,
            "audioOriginSeconds": audioOrigin ?? seekTarget,
            "manualAudioSyncSeconds": activeAudioSyncSeconds,
            "videoPresentationSeconds": presentationTimeSeconds,
            "audioPresentationDelaySeconds": presentationDelaySeconds,
            "audioNodeSampleTime": Double(nodeTime?.sampleTime ?? 0),
            "audioNodeSampleRate": nodeTime?.sampleRate ?? 0,
            "audioOutputSampleRate": outputSampleRate,
            "audioOutputLatencySeconds": outputLatency,
            "audioNodePresentationLatencySeconds": info?.hasAudio == true ? audio.outputPresentationLatency : 0,
            "audioGapFrames": Double(audioGapFrames),
            "insertedAudioSilenceFrames": Double(insertedAudioSilenceFrames),
            "droppedAudioOverlapFrames": Double(droppedAudioOverlapFrames),
            "toleratedAudioTimestampJitterEvents": Double(toleratedAudioTimestampJitterEvents),
            "decodedAudioFrames": Double(decodedAudioFrames), "rebufferCount": Double(rebufferCount),
            "videoBufferSeconds": videoBufferSeconds,
            "videoBufferedAheadSeconds": max(0, videoEnd - mediaTime),
            "isHardwareDecoding": isHardwareDecoding ? 1 : 0,
            "hardwareRecoveryAttempts": Double(hardwareRecoveryAttempts),
            "softwareRecoveryAttempts": Double(softwareRecoveryAttempts)
        ]
    }

    #if DEBUG || SMOOTH_TEST_HOST
    /// Test-only clock diagnostics. Numeric timing only; no device identity or media data.
    var outputClockDiagnosticsForTesting: [String: Double] {
        let render = audio.lastRenderTime
        let now = CACurrentMediaTime()
        var result: [String: Double] = [
            "audioEngineRunning": engine.isRunning ? 1 : 0,
            "audioNodePlaying": audio.isPlaying ? 1 : 0,
            "audioNodeProcessingLatencySeconds": audio.latency,
            "audioMixerProcessingLatencySeconds": engine.mainMixerNode.latency,
            "audioOutputProcessingLatencySeconds": engine.outputNode.latency,
            "audioOutputPresentationLatencySeconds": engine.outputNode.outputPresentationLatency,
            "audioDevicePresentationLatencySeconds": engine.outputNode.presentationLatency,
            "audioRenderTimeValid": render?.isHostTimeValid == true ? 1 : 0,
            "audioRenderSampleRate": render?.sampleRate ?? 0,
        ]
        if let render, render.isHostTimeValid {
            result["audioRenderAgeSeconds"] = now - AVAudioTime.seconds(forHostTime: render.hostTime)
        }
        #if !os(macOS)
        result["audioIOBufferDurationSeconds"] = AVAudioSession.sharedInstance().ioBufferDuration
        #endif
        return result
    }
    #endif

    private func startMonitor() {
        guard monitor == nil else { return }
        startDiagnostics()
        monitor = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !closed, isPlaying {
                if info?.hasAudio == true {
                    let remaining = queuedAudioSeconds
                    let policy = audioBufferingPolicy
                    let videoReady = audioDecoder == nil || videoReachedEOF || videoEnd >= currentTimeSeconds + min(0.15, videoBufferSeconds)
                    let videoStarved = audioDecoder != nil && !videoReachedEOF && videoEnd < currentTimeSeconds + 0.02
                    if !isBuffering, !reachedEOF, remaining < policy.pauseBelowSeconds || videoStarved {
                        bufferingPosition = currentTimeSeconds
                        audio.pause()
                        isBuffering = true
                        rebufferCount += 1
                    } else if isBuffering, videoReady,
                              remaining >= Double(policy.resumeFrames) / 48_000 || (reachedEOF && remaining > 0) {
                        isBuffering = false
                        audio.play()
                    }
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func startDiagnostics() {
        guard diagnosticsTask == nil else { return }
        diagnosticsTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !closed, isPlaying {
            // Snapshots contain media technical properties only; never paths, hostnames,
            // credentials, file names, subtitles, or decoded picture/audio content.
            let metrics = await decoder.diagnosticMetrics()
            guard !Task.isCancelled, !closed else { break }
            latestDiagnostics = metrics
            #if (DEBUG || SMOOTH_PLAYBACK_DIAGNOSTICS) && !os(macOS)
            var sample = metrics
            sample["sampleHostTime"] = ProcessInfo.processInfo.systemUptime
            sample["elapsedSecondsSinceOpen"] = Date().timeIntervalSince(openedAt)
            sample["playbackSeconds"] = currentTimeSeconds
            sample["width"] = Double(info?.width ?? 0); sample["height"] = Double(info?.height ?? 0)
            sample["sourceFPS"] = info?.fps ?? 0
            sample["decodedVideoFrames"] = Double(decodedVideoFrames)
            sample["hardwareDecodedVideoFrames"] = Double(hardwareDecodedVideoFrames)
            sample["isHardwareDecoding"] = isHardwareDecoding ? 1 : 0
            sample["hardwareRecoveryAttempts"] = Double(hardwareRecoveryAttempts)
            sample["softwareRecoveryAttempts"] = Double(softwareRecoveryAttempts)
            sample["audioRenderedFrames"] = Double(audioRenderedFrames)
            sample["audioGapFrames"] = Double(audioGapFrames)
            sample["insertedAudioSilenceFrames"] = Double(insertedAudioSilenceFrames)
            sample["droppedAudioOverlapFrames"] = Double(droppedAudioOverlapFrames)
            sample["toleratedAudioTimestampJitterEvents"] = Double(toleratedAudioTimestampJitterEvents)
            sample["audioOutputSampleRate"] = AVAudioSession.sharedInstance().sampleRate
            sample["audioOutputChannelCount"] = Double(AVAudioSession.sharedInstance().outputNumberOfChannels)
            sample["audioOutputLatencySeconds"] = AVAudioSession.sharedInstance().outputLatency
            sample["audioNodePresentationLatencySeconds"] = info?.hasAudio == true ? audio.outputPresentationLatency : 0
            sample["queuedAudioSeconds"] = queuedAudioSeconds
            sample["videoBufferedAheadSeconds"] = max(0, videoEnd - currentTimeSeconds)
            sample["videoTargetBufferSeconds"] = videoBufferSeconds
            sample["decodedSourcePeakBytes"] = Double(await frames.peakBufferedByteCount)
            sample["rebufferCount"] = Double(rebufferCount)
            sample["isBuffering"] = isBuffering ? 1 : 0
            sample.merge(effectDiagnostics?() ?? [:]) { _, effect in effect }
            // Keep five minutes, including short OFF/ON/fallback changes between
            // snapshots via cumulative counters. No pixels, sound or source identity.
            diagnosticHistory.append(sample)
            if diagnosticHistory.count > 150 { diagnosticHistory.removeFirst(diagnosticHistory.count - 150) }
            let history = diagnosticHistory, sessionID = diagnosticSessionID
            let videoCodec = info?.videoCodec ?? "", audioCodec = info?.audioCodec ?? ""
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
            // Serializing a bounded history still belongs off the display executor.
            await Task.detached(priority: .utility) {
                let report: [String: Any] = ["schema": 2, "build": build, "session": sessionID,
                    "measurements": sample, "history": history,
                    "videoCodec": videoCodec, "audioCodec": audioCodec]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    try? data.write(to: URL.documentsDirectory.appending(path: "playback-diagnostics.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            }.value
            #endif
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func startPump() {
        startSeparateAudioPump()
        guard pump == nil, !closed else { return }
        let token = generation
        pump = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { pump = nil } }
            do {
                while !closed, generation == token, !Task.isCancelled {
                    let now = currentTimeSeconds
                    if reachedEOF {
                        let end = info?.hasAudio == true ? (audioOrigin ?? seekTarget) + Double(audioScheduledFrames) / 48_000 : videoEnd
                        // Rendering the last PCM is earlier than hearing it on Bluetooth.
                        // Keep the output running through its downstream presentation tail.
                        let presented = info?.hasAudio == true ? presentationTimeSeconds : now
                        if isPlaying, presented >= end - 0.001 { pause(); ended = true; onEnded?(); break }
                        try await Task.sleep(for: .milliseconds(20)); continue
                    }
                    if videoReachedEOF {
                        try await Task.sleep(for: .milliseconds(10)); continue
                    }
                    let audioEnd = (audioOrigin ?? seekTarget) + Double(audioScheduledFrames) / 48_000
                    // Bound buffering by decoded pixel memory as well as time, even while paused.
                    if videoEnd > now + videoBufferSeconds, audioDecoder != nil || info?.hasAudio != true || audioEnd > now + min(0.5, videoBufferSeconds) {
                        try await Task.sleep(for: .milliseconds(10)); continue
                    }
                    let event = try await decoder.next()
                    try Task.checkCancellation()
                    guard generation == token, !closed else { break }
                    switch event {
                    case .end:
                        videoReachedEOF = true
                        if audioDecoder == nil { reachedEOF = true }
                        await frames.finish()
                    case .video(let frame):
                        if frame.time + max(0.001, frame.duration) < seekTarget { continue }
                        decodedVideoFrames += 1
                        actualVideoFrameBytes = CVPixelBufferGetDataSize(frame.pixels)
                        containsHDR = containsHDR || frame.isHDR
                        isHardwareDecoding = frame.hardwareDecoded
                        if frame.hardwareDecoded { hardwareDecodedVideoFrames += 1 }
                        if presentationFrames.last.map({ frame.time >= $0.time }) ?? true { presentationFrames.append(frame) }
                        // Also prune without a visible surface (background audio / preparation).
                        let visibleTime = presentationTimeSeconds
                        while presentationFrames.count > 2, presentationFrames[1].time < visibleTime { presentationFrames.removeFirst() }
                        // Retaining the Bluetooth presentation window must not
                        // turn a long external-output delay into unbounded 4K RAM.
                        let maximumFrames = max(2, 256 * 1024 * 1024 / max(1, actualVideoFrameBytes))
                        if presentationFrames.count > maximumFrames {
                            presentationFrames.removeFirst(presentationFrames.count - maximumFrames)
                        }
                        videoEnd = max(videoEnd, frame.time + max(frame.duration, 1 / max(1, info?.fps ?? 24)))
                        await frames.append(frame, keepingFrom: max(0, visibleTime - max(0.05, 1 / max(1, info?.fps ?? 24))))
                    case .audio(let frame):
                        if manualAudioCursor { continue }
                        guard audioDecoder == nil else { throw FFmpegPlaybackError.invalidFrame }
                        try schedule(frame)
                    case .subtitle(let packet):
                        await onSubtitlePacket?(packet)
                    }
                }
            } catch is CancellationError { }
            catch {
                guard !closed, generation == token else { return }
                if case FFmpegPlaybackError.hardwareDecode = error, !recovering {
                    if await recoverVideoOutput() { return }
                    guard !closed else { return }
                }
                fail(error)
            }
        }
    }

    /// Separate video/audio containers keep independent bounded decode queues but
    /// share the same PCM master clock, DSP, pause state and playback generation.
    private func startSeparateAudioPump() {
        guard let audioDecoder, audioPump == nil, !closed else { return }
        let token = generation
        audioPump = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { audioPump = nil } }
            do {
                while !closed, generation == token, !Task.isCancelled, !reachedEOF {
                    let now = currentTimeSeconds
                    let end = (audioOrigin ?? seekTarget) + Double(audioScheduledFrames) / 48_000
                    if end > now + 0.5 {
                        try await Task.sleep(for: .milliseconds(10)); continue
                    }
                    if audioReachedEOF {
                        // AAC priming/trailing padding can leave the audio a little
                        // shorter than video. Silence advances the SAME audio clock
                        // through decoded video's tail; it never creates a new clock.
                        let gap = max(0, videoEnd - end)
                        guard gap.isFinite else { throw FFmpegPlaybackError.invalidFrame }
                        let missing = Int(min(24_000, (gap * 48_000).rounded(.up)))
                        if missing > 0 {
                            // A damaged/incorrect audio stream must not silently
                            // turn the remainder of the movie into long silence.
                            guard separateTailSilenceFrames + Int64(missing) <= 96_000 else { throw FFmpegPlaybackError.invalidFrame }
                            if audioOrigin == nil { audioOrigin = seekTarget }
                            try enqueue(samples: nil, offset: 0, count: missing)
                            separateTailSilenceFrames += Int64(missing)
                            insertedAudioSilenceFrames += Int64(missing)
                        } else if videoReachedEOF { reachedEOF = true; break }
                        else { try await Task.sleep(for: .milliseconds(10)) }
                        continue
                    }
                    let event = try await audioDecoder.next()
                    try Task.checkCancellation()
                    guard generation == token, !closed else { break }
                    switch event {
                    case .audio(let frame):
                        if let end = separateVideoDuration {
                            // Independent AAC tracks can include extra encoder
                            // padding. Keep the user's timeline tied to the video.
                            let remaining = max(0, (end - frame.time) * 48_000)
                            let count = remaining >= Double(frame.frameCount) ? frame.frameCount : Int(remaining.rounded(.up))
                            if count > 0 { try schedule(DecodedAudioFrame(time: frame.time, samples: Array(frame.samples.prefix(count * 2)))) }
                            if count < frame.frameCount { audioReachedEOF = true }
                        } else { try schedule(frame) }
                    case .end: audioReachedEOF = true
                    default: throw FFmpegPlaybackError.invalidFrame
                    }
                }
            } catch is CancellationError { }
            catch {
                guard generation == token, !closed else { return }
                fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        remoteFailure = error as? HTTPSRangeError
        lastError = error.localizedDescription
        generation += 1
        pump?.cancel(); pump = nil
        audioPump?.cancel(); audioPump = nil
        if !recovering { pause(); onFailure?(error.localizedDescription) }
    }

    func recoverVideoOutput() async -> Bool {
        guard !closed, !recovering else { return false }
        let position = currentTimeSeconds
        let resume = requestedPlay
        pause()
        requestedPlay = resume
        recovering = true
        isBuffering = true
        defer { recovering = false; isBuffering = false }
        for preferHardware in [true, false] {
            if preferHardware {
                guard hardwareRecoveryAttempts < 1 else { continue }
                hardwareRecoveryAttempts += 1
            } else {
                guard softwareRecoveryAttempts < 1 else { continue }
                softwareRecoveryAttempts += 1
            }
            guard !closed else { return false }
            generation += 1
            // The caller is the old pump task; advancing its generation is sufficient.
            // Cancelling that task here would also cancel the recovery it is awaiting.
            pump = nil
            audioPump?.cancel(); audioPump = nil
            if info?.hasAudio == true { audio.stop() }
            audioProcessor.reset()
            audioOrigin = nil; audioScheduledFrames = 0; lastAudioRenderedFrames = 0; audioGapFrames = 0
            seekTarget = position; pausedTime = position; bufferingPosition = position; videoEnd = position
            pausedPresentationTime = position
            decodedVideoFrames = 0; decodedAudioFrames = 0
            lastError = nil; reachedEOF = false; ended = false; isHardwareDecoding = false
            videoReachedEOF = false; audioReachedEOF = false
            separateTailSilenceFrames = 0
            presentationFrames.removeAll()
            await frames.reset()
            do {
                try await decoder.recoverVideo(at: position, preferHardware: preferHardware)
                try await audioDecoder?.seek(to: max(0, position - activeAudioSyncSeconds))
                guard !closed else { return false }
                startPump()
                try await waitForPreroll()
                recovering = false; isBuffering = false
                if requestedPlay { play() }
                return true
            } catch { lastError = error.localizedDescription }
        }
        return false
    }

    private func schedule(_ frame: DecodedAudioFrame) throws {
        let shiftedTime = frame.time + activeAudioSyncSeconds
        let skip = min(frame.frameCount, max(0, Int(((seekTarget - shiftedTime) * 48_000).rounded(.up))))
        let count = frame.frameCount - skip
        guard count > 0 else { return }
        let start = shiftedTime + Double(skip) / 48_000
        if audioOrigin == nil { audioOrigin = activeAudioSyncSeconds == 0 ? max(seekTarget, start) : seekTarget }
        // A container's timestamp grid can be coarser than milliseconds. Preserve
        // each decoded packet's continuous samples instead of chasing that jitter.
        let expected = (audioOrigin ?? start) + Double(audioScheduledFrames) / 48_000
        guard let delta = AudioTimestampAlignment.correctionFrames(actualTime: start, expectedTime: expected,
                                                                   packetFrames: frame.frameCount) else {
            throw FFmpegPlaybackError.invalidFrame
        }
        if delta == 0, abs(start - expected) >= 0.5 / 48_000 { toleratedAudioTimestampJitterEvents += 1 }
        if delta > 0 {
            guard delta <= 480_000 else { throw FFmpegPlaybackError.invalidFrame }
            var remaining = delta
            while remaining > 0 { let n = min(remaining, 48_000); try enqueue(samples: nil, offset: 0, count: n); remaining -= n }
            insertedAudioSilenceFrames += Int64(delta)
        }
        let overlap = min(count, max(0, -delta))
        droppedAudioOverlapFrames += Int64(overlap)
        if count > overlap { try enqueue(samples: frame.samples, offset: skip + overlap, count: count - overlap, reference: frame.reference) }
        decodedAudioFrames += count - overlap
    }
    private func enqueue(samples: [Float]?, offset: Int, count: Int, reference: [Float]? = nil) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { throw FFmpegPlaybackError.invalidFrame }
        buffer.frameLength = AVAudioFrameCount(count)
        var processed = samples.map { Array($0[(offset * 2)..<((offset + count) * 2)]) }
            ?? [Float](repeating: 0, count: count * 2)
        let original = reference.map { Array($0[(offset * 2)..<((offset + count) * 2)]) }
        audioProcessor.process(&processed, reference: original)
        for index in 0..<count {
            channels[0][index] = processed[index * 2]
            channels[1][index] = processed[index * 2 + 1]
        }
        onProcessedAudioPCM?(processed, (audioOrigin ?? seekTarget) + Double(audioScheduledFrames) / 48_000)
        audio.scheduleBuffer(buffer)
        audioScheduledFrames += Int64(count)
    }
}
