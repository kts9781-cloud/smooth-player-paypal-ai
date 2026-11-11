import AppKit
import CoreVideo
import MetalKit

/// Invoked only by --self-test; synthetic pixels and a real Metal window, no account or media access.
@MainActor
enum MacSceneBoundaryValidation {
    enum Failure: Error { case check(String) }
    static func run() async throws -> [String: Double] {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw Failure.check(message) }
        }
        func solid(_ value: UInt8) throws -> CVPixelBuffer {
            let pixels = try FrameInterpolator.makePixelBuffer(width: 64, height: 32)
            CVPixelBufferLockBaseAddress(pixels, [])
            defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { throw Failure.check("pixel allocation") }
            let bytes = base.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<32 { for x in 0..<64 {
                for c in 0..<3 { bytes[y * row + x * 4 + c] = value }
                bytes[y * row + x * 4 + 3] = 255
            } }
            return pixels
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        let surface = MTKView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        window.contentView = surface
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let old = try solid(10), next = try solid(240), cut = 5.0 / 24, oldTime = 4.0 / 24
        let frames = FFmpegFrameBuffer()
        await frames.append(DecodedVideoFrame(time: oldTime, duration: 1 / 24, pixels: old, isHDR: false, hardwareDecoded: false), keepingFrom: 0)
        await frames.append(DecodedVideoFrame(time: cut, duration: 1 / 24, pixels: next, isHDR: false, hardwareDecoded: false), keepingFrom: 0)
        await frames.finish()
        let engine = try FrameInterpolator(computeUnits: .cpuOnly)
        let source = MacDelayedBoundarySource(base: FFmpegFrameSource(frames: frames, engine: engine, transform: .identity), cut: cut)
        var clock = 0.0
        let renderer = try SmoothPlaybackCoordinator(source: source, outputFramesPerSecond: 120,
            preparationBatchSize: 2, fallbackFrame: { time in
                DecodedVideoFrame(time: time < cut ? oldTime : cut, duration: 1 / 24,
                    pixels: time < cut ? old : next, isHDR: false, hardwareDecoded: false)
            }, currentTime: { clock }, isPlaying: { true })
        defer { renderer.close(); window.close() }
        try await renderer.prime(at: 0)
        renderer.attach(surface); surface.isPaused = true
        var submitted: [(Double, CVPixelBuffer, Bool)] = []
        renderer.onOwnVideoFrame = { pixels, _, time, generated in submitted.append((time, pixels, generated)) }
        func waitForPresentation(_ count: Int) async throws {
            var retriedDrops = 0
            for _ in 0..<200 {
                if renderer.presentedUniqueFrames >= count { return }
                // This fixture manually drives MTKView. A real running player
                // retries on its next display tick after a discarded drawable.
                if renderer.unpresentedDrawables > retriedDrops {
                    retriedDrops = renderer.unpresentedDrawables
                    surface.draw()
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw Failure.check("Expected \(count) actually displayed pictures; got \(renderer.presentedUniqueFrames), unpresented \(renderer.unpresentedDrawables)")
        }
        clock = 0.195; surface.draw()
        try check(submitted.last.map { abs($0.0 - oldTime) < 0.000_001 } == true, "hold before cut missing")
        // Submitting the next image in the same refresh can discard this one.
        // A zero presentedTime is not proof that the old picture reached screen.
        try await waitForPresentation(1)
        for _ in 0..<100 {
            if await source.waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await source.waiting
        try check(waiting, "controlled delayed prediction not reached")
        clock = cut + 0.001; surface.draw()
        try check(submitted.last.map { abs($0.0 - cut) < 0.000_001 && $0.1 === next && !$0.2 } == true,
            "expired hold postponed decoded next shot")
        try await waitForPresentation(2)
        await source.release()
        for _ in 0..<100 {
            if (await renderer.generationDiagnostics())["queuedFrames", default: 0] >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        clock = cut + 0.012; surface.draw()
        try check(submitted.last.map { $0.0 >= cut } == true, "late previous shot reappeared")
        try check(zip(submitted, submitted.dropFirst()).allSatisfy { $0.0 <= $1.0 }, "visible source time rewound")
        let metrics = await engine.diagnosticMetrics()
        try check(metrics["sceneCutHolds", default: 0] > 0 && metrics["predictionCount"] == 0, "cut not detected")
        // Metal completion publishes presentation counters asynchronously on the main actor.
        for _ in 0..<100 {
            if renderer.presentedUniqueFrames >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try check(renderer.presentedUniqueFrames >= 2 && renderer.lastError == nil, "Metal presentation failed")
        return ["cutTime": cut, "firstNextShotClock": cut + 0.001, "firstNextShotPTS": submitted[1].0,
            "presentedFrames": Double(renderer.presentedUniqueFrames), "sceneCutHolds": metrics["sceneCutHolds", default: 0]]
    }
}

private actor MacDelayedBoundarySource: VideoFrameSource {
    let base: FFmpegFrameSource
    let cut: Double
    let displayTransform = CGAffineTransform.identity
    var generatedFrames: Int { get async { await base.generatedFrames } }
    var lastFrameTimestamp: Double? { get async { await base.lastFrameTimestamp } }
    private var released = false
    private var closed = false
    private(set) var waiting = false
    init(base: FFmpegFrameSource, cut: Double) { self.base = base; self.cut = cut }
    func pixels(at time: Double) async throws -> ImmutableVideoPixels? {
        if time >= cut - 0.000_001 {
            waiting = true
            while !released && !closed { try await Task.sleep(for: .milliseconds(2)) }
        }
        try Task.checkCancellation()
        return try await base.pixels(at: time)
    }
    func release() { released = true }
    func close() { closed = true }
}
