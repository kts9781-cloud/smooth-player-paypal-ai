import CoreVideo
import Foundation

/// Decoders publish immutable pixel buffers. The wrapper transfers ownership across actors;
/// their backing memory is never modified after publication or returned to a pool while retained.
struct ImmutableVideoPixels: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let isSceneCutHold: Bool
    let presentationTime: Double?
    let isGenerated: Bool?
    /// A held source picture must not postpone the next decoded shot while prediction catches up.
    let holdUntil: Double?
    init(buffer: CVPixelBuffer, isSceneCutHold: Bool = false, presentationTime: Double? = nil, isGenerated: Bool? = nil,
         holdUntil: Double? = nil) {
        self.buffer = buffer; self.isSceneCutHold = isSceneCutHold
        self.presentationTime = presentationTime; self.isGenerated = isGenerated
        self.holdUntil = holdUntil
    }
}

protocol VideoFrameSource: Sendable {
    var generatedFrames: Int { get async }
    var displayTransform: CGAffineTransform { get async }
    var lastFrameTimestamp: Double? { get async }
    func pixels(at time: Double) async throws -> ImmutableVideoPixels?
    func close() async
    func diagnosticMetrics() async -> [String: Double]
}

extension MovieFrameInterpolator: VideoFrameSource {
    func pixels(at time: Double) async throws -> ImmutableVideoPixels? {
        try await delivery(at: time)
    }
}

extension VideoFrameSource {
    func diagnosticMetrics() async -> [String: Double] { [:] }
}

actor FFmpegFrameBuffer {
    private var frames: [DecodedVideoFrame] = []
    private var ended = false
    private(set) var bufferedByteCount = 0
    private(set) var peakBufferedByteCount = 0
    var bufferedFrameCount: Int { frames.count }
    func append(_ frame: DecodedVideoFrame, keepingFrom time: Double) {
        if let last = frames.last, frame.time < last.time { return }
        frames.append(frame)
        bufferedByteCount += CVPixelBufferGetDataSize(frame.pixels)
        peakBufferedByteCount = max(peakBufferedByteCount, bufferedByteCount)
        while frames.count > 2, frames[1].time < time || bufferedByteCount > 256 * 1024 * 1024 {
            bufferedByteCount -= CVPixelBufferGetDataSize(frames.removeFirst().pixels)
        }
    }
    func reset() { frames.removeAll(); bufferedByteCount = 0; ended = false }
    func finish() { ended = true }
    func latest(at time: Double) -> DecodedVideoFrame? {
        frames.last(where: { $0.time <= time + 0.002 }) ?? frames.first
    }
    func pair(at time: Double) async throws -> (DecodedVideoFrame, DecodedVideoFrame?)? {
        // A slow HTTP range is a buffering condition, not an interpolation
        // failure. The transport owns its timeout; seek/close cancels this task.
        while true {
            try Task.checkCancellation()
            if let last = frames.last, ended || last.time > time + 0.001 {
                let index = frames.lastIndex(where: { $0.time <= time + 0.001 }) ?? 0
                return (frames[index], index + 1 < frames.count ? frames[index + 1] : nil)
            }
            if ended { return frames.last.map { ($0, nil) } }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

actor FFmpegFrameSource: VideoFrameSource {
    private let frames: FFmpegFrameBuffer
    private let engine: FrameInterpolator?
    let displayTransform: CGAffineTransform
    private(set) var lastFrameTimestamp: Double?
    private var lastFrameWasSceneCut = false
    private(set) var generatedFrames = 0
    private var pairWaitSeconds = 0.0
    private var pairRequests = 0
    init(frames: FFmpegFrameBuffer, engine: FrameInterpolator?, transform: CGAffineTransform) {
        self.frames = frames; self.engine = engine; displayTransform = transform
    }
    func pixels(at time: Double) async throws -> ImmutableVideoPixels? {
        guard let frame = try await frame(at: time) else { return nil }
        guard let engine else { return frame }
        let pixels = try await engine.presentationPixels(frame.buffer)
        return ImmutableVideoPixels(buffer: pixels, isSceneCutHold: frame.isSceneCutHold,
                                    presentationTime: frame.presentationTime, isGenerated: frame.isGenerated, holdUntil: frame.holdUntil)
    }
    private func frame(at time: Double) async throws -> ImmutableVideoPixels? {
        lastFrameWasSceneCut = false
        guard let engine else {
            guard let frame = await frames.latest(at: time) else { return nil }
            lastFrameTimestamp = frame.time
            return ImmutableVideoPixels(buffer: frame.pixels, presentationTime: frame.time, isGenerated: false)
        }
        let pairStart = Date.timeIntervalSinceReferenceDate
        guard let (a, b) = try await frames.pair(at: time) else { return nil }
        pairWaitSeconds += Date.timeIntervalSinceReferenceDate - pairStart
        pairRequests += 1
        guard let b, b.time > a.time else {
            lastFrameTimestamp = a.time
            return ImmutableVideoPixels(buffer: a.pixels, presentationTime: a.time, isGenerated: false)
        }
        let fraction = Float(min(1, max(0, (time - a.time) / (b.time - a.time))))
        lastFrameTimestamp = time
        // Millisecond container timestamps round exact 24 fps boundaries. Reuse the
        // original image within that quantization error instead of inferring a nearly
        // identical frame at every nominal source boundary.
        if fraction <= 0.001 || abs(time - a.time) <= 0.001 {
            lastFrameTimestamp = a.time
            return ImmutableVideoPixels(buffer: a.pixels, presentationTime: a.time, isGenerated: false)
        }
        if fraction >= 0.999 || abs(b.time - time) <= 0.001 {
            lastFrameTimestamp = b.time
            return ImmutableVideoPixels(buffer: b.pixels, presentationTime: b.time, isGenerated: false)
        }
        let output = try await engine.interpolate(first: a.pixels, second: b.pixels, fraction: fraction)
        try Task.checkCancellation()
        let held = output === a.pixels
        let generated = output !== a.pixels && output !== b.pixels
        let timestamp = held ? a.time : (output === b.pixels ? b.time : time)
        lastFrameTimestamp = timestamp; lastFrameWasSceneCut = held
        if generated { generatedFrames += 1 }
        return ImmutableVideoPixels(buffer: output, isSceneCutHold: held, presentationTime: timestamp, isGenerated: generated,
                                    holdUntil: held ? b.time : nil)
    }
    func close() { }
    func diagnosticMetrics() async -> [String: Double] {
        var report = await engine?.diagnosticMetrics() ?? [:]
        report["pairWaitSeconds"] = pairWaitSeconds
        report["pairRequests"] = Double(pairRequests)
        return report
    }
}
