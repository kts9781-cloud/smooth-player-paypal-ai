import CoreVideo
import Foundation
import SmoothPlayerFFmpeg

struct DecodedVideoFrame: @unchecked Sendable {
    let time: Double
    let duration: Double
    let pixels: CVPixelBuffer
    let isHDR: Bool
    let hardwareDecoded: Bool
}
struct DecodedAudioFrame: Sendable {
    let time: Double
    let samples: [Float]
    var reference: [Float]? = nil
    var frameCount: Int { samples.count / 2 }
}
enum DecodedMediaEvent: @unchecked Sendable {
    case video(DecodedVideoFrame), audio(DecodedAudioFrame), subtitle(NativeSubtitlePacket), end
}
struct FFmpegMediaInfo: Sendable {
    let duration: Double
    /// Original container start before the native decoder's zero normalization.
    let timelineOrigin: Double
    let fps: Double
    let width: Int
    let height: Int
    let hasAudio: Bool
    let rotation: Double
    let sampleAspectRatio: Double
    let isHDR: Bool
    let videoCodec: String
    let audioCodec: String
    var enhancementSDR: Bool = false
    var lowResolutionSource: LowResolutionSource {
        LowResolutionSource(width: width, height: height, verifiedSDR: enhancementSDR && !isHDR)
    }
}
enum FFmpegPlaybackError: LocalizedError {
    case decode(Int32), hardwareDecode(Int32), invalidFrame, noVideo, closed
    var errorDescription: String? {
        switch self {
        case .decode(let code), .hardwareDecode(let code):
            var bytes = [CChar](repeating: 0, count: 256)
            sp_ff_error_string(code, &bytes, Int32(bytes.count))
            return SPText("동영상을 읽지 못했습니다. (\(String(cString: bytes)))")
        case .invalidFrame: return SPText("동영상의 프레임 정보가 올바르지 않습니다.")
        case .noVideo: return SPText("영상 트랙을 찾지 못했습니다.")
        case .closed: return SPText("재생이 종료되었습니다.")
        }
    }
}

/// AVIO executes on the dedicated decoder queue. The NAS request executes on its own
/// connection queue, never the decoder queue or main actor. Only synthetic byte ranges cross.
private final class FFmpegNetworkIO: @unchecked Sendable {
    let stream: any MediaByteStream
    private var offset: Int64 = 0 // Decoder queue only.
    private struct Window { let offset: Int64; let data: Data }
    private var windows: [Window] = []
    private var maximumWindows = 32
    private var windowBytes = 1_048_576
    private var cacheMegabytes: Int
    private let readAhead: MediaReadAhead?
    private var readAheadEnabled = false
    private(set) var readAheadHits = 0
    private(set) var readWaitSeconds = 0.0
    private(set) var sourceReadCalls = 0
    private(set) var sourceBytes = 0
    private(set) var returnedBytes = 0
    private(set) var cacheHits = 0
    private(set) var seekCalls = 0
    private(set) var sourceReadSeconds = 0.0
    private(set) var maximumReadSeconds = 0.0
    private(set) var remoteFailure: HTTPSRangeError?
    private let lock = NSLock()
    private var cancelled = false
    init(_ stream: any MediaByteStream, cacheMegabytes: Int, prefetch: Bool) {
        self.stream = stream
        self.cacheMegabytes = min(128, max(16, cacheMegabytes))
        maximumWindows = self.cacheMegabytes
        readAhead = prefetch ? MediaReadAhead(stream: stream) : nil
    }
    func setCacheMegabytes(_ value: Int) {
        cacheMegabytes = min(128, max(16, value))
        maximumWindows = cacheMegabytes * 1_048_576 / windowBytes
        if windows.count > maximumWindows { windows.removeFirst(windows.count - maximumWindows) }
    }
    func enableReadAhead(highResolutionVideo: Bool) {
        // A 1 MiB reserve is less than a second of 4K. Use two 4 MiB ranges
        // instead of many competing small transfers, with the same byte cache
        // budget. NAS, audio, probes and <=1080p keep their original small reads.
        if highResolutionVideo, stream is HTTPSRangeStream, let readAhead {
            windowBytes = 4 * 1_048_576
            setCacheMegabytes(cacheMegabytes)
            readAhead.configure(maximumWindows: 2, windowBytes: windowBytes)
        }
        readAheadEnabled = true
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); readAhead?.close() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func read(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int32 {
        guard !isCancelled else { return -5 }
        if offset >= stream.size { return 0 }
        let window: Window
        if let index = windows.firstIndex(where: { offset >= $0.offset && offset < $0.offset + Int64($0.data.count) }) {
            window = windows.remove(at: index)
            windows.append(window)
            cacheHits += 1
        } else {
            let position = offset
            // FTP's native range reader opens a transfer for each read. A bounded 1 MiB window
            // amortizes that setup over AVIO's smaller requests, without downloading the file.
            let started = Date.timeIntervalSinceReferenceDate
            let prefetched = readAhead?.take(at: position)
            if prefetched != nil { readAheadHits += 1 }
            let request = prefetched ?? MediaReadRequest(stream: stream, offset: position, count: windowBytes)
            let deadline = DispatchTime.now() + 12
            while request.ready.wait(timeout: .now() + .milliseconds(50)) != .success {
                if isCancelled || DispatchTime.now() >= deadline {
                    request.cancel()
                    if !isCancelled, stream is HTTPSRangeStream { remoteFailure = .connectionFailed }
                    return -5
                }
            }
            if let error = request.remoteFailure { remoteFailure = error }
            guard !isCancelled, let data = request.data else { return -5 }
            let elapsed = request.elapsed
            readWaitSeconds += max(0, Date.timeIntervalSinceReferenceDate - started)
            sourceReadCalls += 1; sourceBytes += data.count
            sourceReadSeconds += elapsed; maximumReadSeconds = max(maximumReadSeconds, elapsed)
            window = Window(offset: position, data: data)
            windows.append(window)
            if windows.count > maximumWindows { windows.removeFirst(windows.count - maximumWindows) }
        }
        let nextOffset = window.offset + Int64(window.data.count)
        if readAheadEnabled, nextOffset < stream.size,
           !windows.contains(where: { nextOffset >= $0.offset && nextOffset < $0.offset + Int64($0.data.count) }) {
            readAhead?.prefetch(at: nextOffset)
        }
        let index = Int(offset - window.offset)
        let count = min(capacity, window.data.count - index)
        guard count > 0 else { return 0 }
        _ = window.data.withUnsafeBytes { bytes in
            memcpy(buffer, bytes.baseAddress!.advanced(by: index), count)
        }
        offset += Int64(count)
        returnedBytes += count
        return Int32(count)
    }
    func seek(offset value: Int64, whence: Int32) -> Int64 {
        guard !isCancelled else { return -1 }
        if whence & Int32(SP_FF_SEEK_SIZE) != 0 { return stream.size }
        let mode = whence & ~Int32(0x20000)
        let base: Int64
        switch mode { case 0: base = 0; case 1: base = offset; case 2: base = stream.size; default: return -1 }
        let result = base.addingReportingOverflow(value)
        guard !result.overflow, result.partialValue >= 0, result.partialValue <= stream.size else { return -1 }
        if offset != result.partialValue {
            seekCalls += 1
            // A nonsequential seek must not use bytes for the old target.
            readAhead?.discard()
        }
        offset = result.partialValue
        return offset
    }
}

/// FFmpeg's mutable state and borrowed output buffers are confined to one serial queue.
final class FFmpegDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nodelabs.smoothplayer.decode", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var networkIO: FFmpegNetworkIO?
    private var pixelPool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private let cancelLock = NSLock()
    private var cancelled = false
    private var nextCalls = 0
    private var nextSeconds = 0.0
    private var maximumNextSeconds = 0.0
    private var videoCopySeconds = 0.0
    private var zeroCopyVideoFrames = 0
    private var isCancelled: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelled }

    private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func open(url: URL?, stream: (any MediaByteStream)?, cacheMegabytes: Int = 32, requireVideo: Bool = true,
              prefetch: Bool = false, audioOnly: Bool = false) async throws -> FFmpegMediaInfo {
        try await perform {
            guard !self.isCancelled else { throw CancellationError() }
            var error: Int32 = 0
            let native: OpaquePointer?
            if let stream {
                let io = FFmpegNetworkIO(stream, cacheMegabytes: cacheMegabytes, prefetch: prefetch)
                self.cancelLock.lock()
                self.networkIO = io
                if self.cancelled { io.cancel() }
                self.cancelLock.unlock()
                let read: sp_ff_read_callback = { opaque, bytes, size in
                    guard let opaque, let bytes, size > 0 else { return -5 }
                    return Unmanaged<FFmpegNetworkIO>.fromOpaque(opaque).takeUnretainedValue().read(into: bytes, capacity: Int(size))
                }
                let seek: sp_ff_seek_callback = { opaque, offset, whence in
                    guard let opaque else { return -1 }
                    return Unmanaged<FFmpegNetworkIO>.fromOpaque(opaque).takeUnretainedValue().seek(offset: offset, whence: whence)
                }
                let opaque = Unmanaged.passUnretained(io).toOpaque()
                native = audioOnly ? sp_ff_open_audio_io(opaque, read, seek, &error) : sp_ff_open_io(opaque, read, seek, 1, &error)
            } else if let url, url.isFileURL {
                native = url.path.withCString { audioOnly ? sp_ff_open_audio_file($0, &error) : sp_ff_open_file($0, 1, &error) }
            } else { throw FFmpegPlaybackError.closed }
            if let failure = self.networkIO?.remoteFailure {
                if let native { sp_ff_close(native) }
                throw failure
            }
            if self.isCancelled { if let native { sp_ff_close(native) }; throw CancellationError() }
            guard let native else { throw FFmpegPlaybackError.decode(error) }
            self.cancelLock.lock()
            if self.cancelled { self.cancelLock.unlock(); sp_ff_close(native); throw CancellationError() }
            self.handle = native
            self.cancelLock.unlock()
            var info = sp_ff_info()
            let status = sp_ff_get_info(native, &info)
            guard status >= 0 else { throw FFmpegPlaybackError.decode(status) }
            if requireVideo {
                guard info.has_video != 0 else { throw FFmpegPlaybackError.noVideo }
            } else {
                // A second input must be audio-only: never silently decode a
                // second video or mix its embedded audio with the video input.
                guard info.has_audio != 0, info.has_video == 0 else { throw FFmpegPlaybackError.invalidFrame }
            }
            // Container probing may jump between the header/index and first packets.
            // Speculate only once probing has finished and playback starts decoding.
            self.networkIO?.enableReadAhead(highResolutionVideo: requireVideo && Int64(info.width) * Int64(info.height) > 1_920 * 1_080)
            return FFmpegMediaInfo(duration: max(0, info.duration_seconds), timelineOrigin: sp_ff_timeline_origin(native), fps: info.frames_per_second,
                                   width: Int(info.width), height: Int(info.height), hasAudio: info.has_audio != 0,
                                   rotation: info.rotation_degrees, sampleAspectRatio: info.sample_aspect_ratio, isHDR: info.is_hdr != 0,
                                   videoCodec: withUnsafePointer(to: &info.video_codec) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) },
                                   audioCodec: withUnsafePointer(to: &info.audio_codec) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) },
                                   enhancementSDR: sp_ff_enhancement_sdr(native) != 0)
        }
    }
    private var soundFocus: Float = 0
    private var captureSoundReference = false
    func setSoundOptions(focus: Float, reference: Bool) {
        queue.async { self.soundFocus = focus; self.captureSoundReference = reference }
    }
    func next() async throws -> DecodedMediaEvent {
        try await perform {
            guard let handle = self.handle else { throw FFmpegPlaybackError.closed }
            var event = sp_ff_frame()
            let started = Date.timeIntervalSinceReferenceDate
            sp_ff_set_sound_options(handle, self.soundFocus, self.captureSoundReference ? 1 : 0)
            let status = sp_ff_next(handle, &event)
            if let failure = self.networkIO?.remoteFailure { throw failure }
            let elapsed = max(0, Date.timeIntervalSinceReferenceDate - started)
            self.nextCalls += 1; self.nextSeconds += elapsed; self.maximumNextSeconds = max(self.maximumNextSeconds, elapsed)
            guard status >= 0 else {
                if sp_ff_is_hardware_error(handle, status) != 0 { throw FFmpegPlaybackError.hardwareDecode(status) }
                throw FFmpegPlaybackError.decode(status)
            }
            if status == SP_FF_EOF { return .end }
            guard event.pts_seconds.isFinite else { throw FFmpegPlaybackError.invalidFrame }
            if status == SP_FF_SUBTITLE {
                guard let bytes = event.data, event.data_bytes > 0, event.data_bytes <= 4 * 1024 * 1024,
                      event.subtitle_stream >= 0, event.duration_seconds.isFinite else { throw FFmpegPlaybackError.invalidFrame }
                return .subtitle(NativeSubtitlePacket(trackID: event.subtitle_stream, data: Data(bytes: bytes, count: Int(event.data_bytes)),
                                                       time: event.pts_seconds, duration: max(0, event.duration_seconds)))
            }
            if status == SP_FF_AUDIO {
                guard let bytes = event.data, event.audio_sample_rate == 48_000, event.audio_channels == 2,
                      event.audio_frames > 0, event.audio_frames <= 192_000,
                      event.data_bytes >= event.audio_frames * 8 else { throw FFmpegPlaybackError.invalidFrame }
                let samples = bytes.withMemoryRebound(to: Float.self, capacity: Int(event.audio_frames) * 2) {
                    Array(UnsafeBufferPointer(start: $0, count: Int(event.audio_frames) * 2))
                }
                var referenceCount: Int32 = 0
                let pointer = sp_ff_unfocused_audio(handle, &referenceCount)
                let reference = pointer != nil && Int(referenceCount) == samples.count
                    ? Array(UnsafeBufferPointer(start: pointer!, count: samples.count)) : nil
                return .audio(DecodedAudioFrame(time: event.pts_seconds, samples: samples, reference: reference))
            }
            if status == SP_FF_VIDEO, let pointer = event.cv_pixelbuffer {
                // Retain while still on the decoder worker, before the next native call can
                // release its AVFrame. Preserve NV12/P010 and color attachments for GPU display.
                let pixels = Unmanaged<CVPixelBuffer>.fromOpaque(pointer).retain().takeRetainedValue()
                guard CVPixelBufferGetWidth(pixels) == Int(event.width),
                      CVPixelBufferGetHeight(pixels) == Int(event.height) else { throw FFmpegPlaybackError.invalidFrame }
                var info = sp_ff_info()
                _ = sp_ff_get_info(handle, &info)
                self.zeroCopyVideoFrames += 1
                return .video(DecodedVideoFrame(time: event.pts_seconds, duration: event.duration_seconds,
                    pixels: pixels, isHDR: info.is_hdr != 0, hardwareDecoded: true))
            }
            guard status == SP_FF_VIDEO, let bytes = event.data, event.width > 0, event.height > 0,
                  event.width <= 16_384, event.height <= 16_384,
                  Int64(event.width) * Int64(event.height) <= 33_554_432,
                  event.stride >= event.width * 4,
                  Int64(event.data_bytes) >= Int64(event.stride) * Int64(event.height) else { throw FFmpegPlaybackError.invalidFrame }
            let copyStarted = Date.timeIntervalSinceReferenceDate
            let width = Int(event.width), height = Int(event.height)
            if self.pixelPool == nil || self.poolSize != (width, height) {
                let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
                guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &self.pixelPool) == kCVReturnSuccess else { throw FFmpegPlaybackError.invalidFrame }
                self.poolSize = (width, height)
            }
            var output: CVPixelBuffer?
            guard let pool = self.pixelPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
                  let output else { throw FFmpegPlaybackError.invalidFrame }
            CVPixelBufferLockBaseAddress(output, [])
            defer { CVPixelBufferUnlockBaseAddress(output, []) }
            guard let base = CVPixelBufferGetBaseAddress(output) else { throw FFmpegPlaybackError.invalidFrame }
            let stride = CVPixelBufferGetBytesPerRow(output)
            for row in 0..<height { memcpy(base.advanced(by: row * stride), bytes.advanced(by: row * Int(event.stride)), width * 4) }
            self.videoCopySeconds += max(0, Date.timeIntervalSinceReferenceDate - copyStarted)
            var info = sp_ff_info()
            _ = sp_ff_get_info(handle, &info)
            return .video(DecodedVideoFrame(time: event.pts_seconds, duration: event.duration_seconds, pixels: output,
                                           isHDR: info.is_hdr != 0, hardwareDecoded: info.hardware_decoding != 0))
        }
    }
    func diagnosticMetrics() async -> [String: Double] {
        (try? await perform {
            var values: [String: Double] = ["decoderNextCalls": Double(self.nextCalls), "decoderNextSeconds": self.nextSeconds,
                                           "maximumDecoderNextSeconds": self.maximumNextSeconds,
                                           "softwareVideoCopySeconds": self.videoCopySeconds, "zeroCopyVideoFrames": Double(self.zeroCopyVideoFrames)]
            if let io = self.networkIO {
                values.merge(["networkReadCalls": Double(io.sourceReadCalls), "networkFetchedBytes": Double(io.sourceBytes),
                              "networkDeliveredBytes": Double(io.returnedBytes), "networkCacheHits": Double(io.cacheHits),
                              "networkSeekCalls": Double(io.seekCalls), "networkReadSeconds": io.sourceReadSeconds,
                              "networkReadAheadHits": Double(io.readAheadHits), "networkReadWaitSeconds": io.readWaitSeconds,
                              "maximumNetworkReadSeconds": io.maximumReadSeconds]) { _, new in new }
            }
            return values
        }) ?? [:]
    }

    func subtitleTracks() async throws -> [EmbeddedSubtitleTrack] {
        try await perform {
            guard let handle = self.handle else { throw FFmpegPlaybackError.closed }
            let count = sp_ff_subtitle_count(handle)
            guard (0...256).contains(count) else { throw FFmpegPlaybackError.invalidFrame }
            return try (0..<count).map { ordinal in
                var track = sp_ff_subtitle_track()
                let status = sp_ff_subtitle_get(handle, ordinal, &track)
                guard status >= 0 else { throw FFmpegPlaybackError.decode(status) }
                guard track.extradata_size >= 0, track.extradata_size <= 1024 * 1024 else { throw FFmpegPlaybackError.invalidFrame }
                let extra: Data
                if let pointer = track.extradata, track.extradata_size > 0 { extra = Data(bytes: pointer, count: Int(track.extradata_size)) }
                else { extra = Data() }
                return EmbeddedSubtitleTrack(id: track.stream_index, codecID: track.codec_id,
                    language: withUnsafePointer(to: &track.language) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) },
                    title: withUnsafePointer(to: &track.title) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) },
                    codecName: withUnsafePointer(to: &track.codec_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) },
                    isDefault: track.is_default != 0, isForced: track.is_forced != 0, supported: track.supported_text != 0, extraData: extra)
            }
        }
    }

    func selectSubtitle(_ id: Int32?) async throws {
        try await perform {
            guard let handle = self.handle else { throw FFmpegPlaybackError.closed }
            let status = sp_ff_subtitle_select(handle, id ?? -1)
            guard status >= 0 else { throw FFmpegPlaybackError.decode(status) }
        }
    }

    func recoverVideo(at time: Double, preferHardware: Bool) async throws {
        try await perform {
            guard let handle = self.handle else { throw FFmpegPlaybackError.closed }
            let status = sp_ff_recover_video(handle, time, preferHardware ? 1 : 0)
            if let failure = self.networkIO?.remoteFailure { throw failure }
            guard status >= 0 else { throw FFmpegPlaybackError.decode(status) }
        }
    }

    func seek(to time: Double) async throws {
        try await perform {
            guard let handle = self.handle else { throw FFmpegPlaybackError.closed }
            let status = sp_ff_seek(handle, time)
            if let failure = self.networkIO?.remoteFailure { throw failure }
            guard status >= 0 else { throw FFmpegPlaybackError.decode(status) }
        }
    }
    func cancel() {
        cancelLock.lock(); defer { cancelLock.unlock() }
        cancelled = true
        networkIO?.cancel()
        if let handle { sp_ff_cancel(handle) }
    }
    func close() async {
        cancel()
        await withCheckedContinuation { continuation in
          queue.async {
            self.cancelLock.lock()
            let native = self.handle
            let io = self.networkIO
            self.handle = nil
            self.networkIO = nil
            self.cancelLock.unlock()
            withExtendedLifetime(io) { if let native { sp_ff_close(native) } }
            self.pixelPool = nil
            if let stream = io?.stream { Task { await stream.close() } }
            continuation.resume()
          }
        }
    }
}
