import AVFoundation
import CoreVideo
import Foundation

/// Sequential video decoder and timestamp-based interpolation source for the future real-time
/// scheduler. It produces real intermediate frames from local video; it does not alter audio.
actor MovieFrameInterpolator {
    private struct Frame { let time: Double; let pixels: CVPixelBuffer }
    private let asset: AVAsset
    private let engine: FrameInterpolator
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var previous: Frame?
    private var next: Frame?
    private var lastRequestedTime: Double = -1
    private(set) var generatedFrames = 0
    private(set) var lastFrameTimestamp: Double?
    private(set) var lastFrameWasSceneCut = false
    private(set) var displayTransform: CGAffineTransform = .identity

    init(url: URL, engine: FrameInterpolator) throws {
        guard url.isFileURL else { throw MediaError.localFilesOnly }
        asset = AVURLAsset(url: url)
        self.engine = engine
    }

    init(asset: AVAsset, engine: FrameInterpolator) {
        self.asset = asset
        self.engine = engine
    }

    func frame(at time: Double) async throws -> CVPixelBuffer? {
        try await delivery(at: time)?.buffer
    }
    func delivery(at time: Double) async throws -> ImmutableVideoPixels? {
        guard let frame = try await originalSizeFrame(at: time) else { return nil }
        // Keep metadata with its picture across actor suspension, as in the FFmpeg source.
        let pixels = try await engine.presentationPixels(frame.buffer)
        return ImmutableVideoPixels(buffer: pixels, isSceneCutHold: frame.isSceneCutHold,
                                    presentationTime: frame.presentationTime, isGenerated: frame.isGenerated, holdUntil: frame.holdUntil)
    }
    private func originalSizeFrame(at time: Double) async throws -> ImmutableVideoPixels? {
        lastFrameWasSceneCut = false
        guard time.isFinite, time >= 0 else { throw FrameGenerationError.invalidPrediction }
        try Task.checkCancellation()
        // Recreate after a backwards seek or a large forward jump instead of decoding the skipped movie.
        if output == nil || time < lastRequestedTime || time - lastRequestedTime > 1 {
            try await reset(at: max(0, time - 0.15))
        }
        lastRequestedTime = time
        if previous == nil { previous = try readFrame() }
        if next == nil { next = try readFrame() }
        while let end = next, end.time <= time {
            previous = end
            next = try readFrame()
        }
        guard let a = previous else { return nil }
        guard let b = next, b.time > a.time else {
            lastFrameTimestamp = a.time
            return ImmutableVideoPixels(buffer: a.pixels, presentationTime: a.time, isGenerated: false)
        }
        let fraction = Float(min(1, max(0, (time - a.time) / (b.time - a.time))))
        if fraction < 0.001 {
            lastFrameTimestamp = a.time
            return ImmutableVideoPixels(buffer: a.pixels, presentationTime: a.time, isGenerated: false)
        }
        if fraction > 0.999 {
            lastFrameTimestamp = b.time
            return ImmutableVideoPixels(buffer: b.pixels, presentationTime: b.time, isGenerated: false)
        }
        let result = try await engine.interpolate(first: a.pixels, second: b.pixels, fraction: fraction)
        try Task.checkCancellation()
        let held = result === a.pixels
        let generated = result !== a.pixels && result !== b.pixels
        if held { lastFrameTimestamp = a.time; lastFrameWasSceneCut = true }
        else if result === b.pixels { lastFrameTimestamp = b.time }
        else { lastFrameTimestamp = time; generatedFrames += 1 }
        return ImmutableVideoPixels(buffer: result, isSceneCutHold: held, presentationTime: lastFrameTimestamp,
                                    isGenerated: generated, holdUntil: held ? b.time : nil)
    }

    func close() {
        reader?.cancelReading()
        reader = nil
        output = nil
        previous = nil
        next = nil
        lastRequestedTime = -1
    }

    private func reset(at start: Double) async throws {
        close()
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.unsupportedFormat }
        let characteristics = try await track.load(.mediaCharacteristics)
        guard !characteristics.contains(.containsHDRVideo) else { throw FrameGenerationError.unsupportedDynamicRange }
        displayTransform = try await track.load(.preferredTransform).videoTrackToCoreImage
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                       kCVPixelBufferMetalCompatibilityKey as String: true,
                                       kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaError.unsupportedFormat }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000), duration: .positiveInfinity)
        guard reader.startReading() else { throw reader.error ?? MediaError.unsupportedFormat }
        self.reader = reader
        self.output = output
    }

    private func readFrame() throws -> Frame? {
        guard let sample = output?.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) else {
            if reader?.status == .failed { throw reader?.error ?? MediaError.unsupportedFormat }
            if reader?.status == .cancelled { throw CancellationError() }
            return nil
        }
        return Frame(time: CMSampleBufferGetPresentationTimeStamp(sample).seconds, pixels: pixels)
    }
}

extension CGAffineTransform {
    /// AV track matrices use image coordinates (Y down), while CIImage uses Y up.
    /// Conjugate by a vertical reflection; the renderer normalizes the final extent.
    /// This preserves mirror/scale components as well as quarter-turn rotations.
    var videoTrackToCoreImage: CGAffineTransform {
        CGAffineTransform(a: a, b: -b, c: -c, d: d, tx: tx, ty: -ty)
    }
}
