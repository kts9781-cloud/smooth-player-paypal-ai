import AVFoundation
import CoreImage
import CoreVideo
import MetalKit

/// A host with an explicit display link (Mac) controls that link instead of MTKView's timer.
@MainActor
protocol PresentationClockControl: AnyObject {
    func setPresentationClockPaused(_ paused: Bool)
}

#if os(iOS)
/// The explicit display clock supplies the actual upcoming refresh to the renderer.
/// MTKView still owns drawable lifetime through draw(), with its implicit timer off.
@MainActor
final class SmoothPlayerMetalView: MTKView, PresentationClockControl {
    private var displayClock: CADisplayLink?
    private var clockRate = 0
    private var presentationClockPaused = false
    var isPresentationClockPaused: Bool { displayClock?.isPaused ?? true }
    func setPresentationClockPaused(_ paused: Bool) {
        presentationClockPaused = paused
        configureDisplayClock()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        configureDisplayClock()
    }
    private func configureDisplayClock() {
        isPaused = true
        enableSetNeedsDisplay = false
        guard window != nil, delegate != nil else { stopDisplayClock(); return }
        if displayClock == nil {
            let clock = CADisplayLink(target: ClockTarget(view: self), selector: #selector(ClockTarget.tick(_:)))
            clock.add(to: .main, forMode: .common)
            displayClock = clock
        }
        displayClock?.isPaused = presentationClockPaused
        let rate = max(1, preferredFramesPerSecond)
        if rate != clockRate {
            displayClock?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
            clockRate = rate
        }
    }
    func stopDisplayClock() { displayClock?.invalidate(); displayClock = nil; clockRate = 0 }
    deinit { displayClock?.invalidate() }
    @MainActor private final class ClockTarget: NSObject {
        weak var view: SmoothPlayerMetalView?
        init(view: SmoothPlayerMetalView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) {
            guard let view, let renderer = view.delegate as? SmoothPlaybackCoordinator else { return }
            renderer.draw(view, at: link.targetTimestamp, interval: link.targetTimestamp - link.timestamp)
        }
    }
}
#endif

/// Audio-master presentation queue for the real interpolation pipeline. The debug UI exercises
/// this implementation; production availability remains gated on device and thermal validation.
@MainActor
final class SmoothPlaybackCoordinator: NSObject, MTKViewDelegate {
    private typealias ScheduledFrame = ScheduledVideoFrame
    private let currentTime: @MainActor () -> Double
    private let mediaTimeAtHostTime: (@MainActor (Double) -> Double)?
    private let isPlaying: @MainActor () -> Bool
    private let ordinary: Bool
    private let preparationBatchSize: Int
    private let ordinaryFrame: (@MainActor (Double) -> DecodedVideoFrame?)?
    private let fallbackFrame: (@MainActor (Double) -> DecodedVideoFrame?)?
    private let ordinaryTransform: CGAffineTransform
    private let source: any VideoFrameSource
    private let device: MTLDevice
    private let context: CIContext
    private let commands: MTLCommandQueue
    private let enhancer: VideoEnhancer
    var videoScaleMode: VideoScaleMode = .fit { didSet { if oldValue != videoScaleMode { invalidatePicture() } } }
    var edgeUpscaling = false { didSet { if oldValue != edgeUpscaling { invalidatePicture() } } }
    var lowResolutionEnhancement = false { didSet { if oldValue != lowResolutionEnhancement { invalidatePicture() } } }
    var lowResolutionSource: LowResolutionSource? { didSet { if oldValue != lowResolutionSource { invalidatePicture() } } }
    private(set) var lowResolutionStatus = SPText("영상 준비 중")
    // TV still receives raw/generated source frames at the original cadence. Only
    // the covered handset picture skips its redundant Core Image enhancement.
    var localVideoHidden = false { didSet {
        if oldValue != localVideoHidden { refreshDisplayClock(); invalidatePicture() }
    } }
    var budgetAllowsEdgeUpscaling: Bool { edgeUpscaling && !enhancementBudget.isLimited }
    private(set) var effectiveEdgeUpscaling = false
    private var enhancementBudget = VideoEnhancementBudget(mode: .off)
    var enhancementMode: VideoEnhancementMode {
        get { enhancementBudget.requested }
        set { if newValue != enhancementBudget.requested { enhancementBudget.select(newValue); invalidatePicture() } }
    }
    private(set) var effectiveEnhancementMode: VideoEnhancementMode = .off
    var enhancementAutomaticReduction: Bool {
        get { enhancementBudget.automaticReduction }
        set { if newValue != enhancementBudget.automaticReduction { enhancementBudget.setAutomaticReduction(newValue); invalidatePicture() } }
    }
    var enhancementStatus: String {
        if enhancementMode == .off { return SPText("현재 적용: 끔") }
        if !enhancer.isAvailable { return SPText("이 기기에서 보정 셰이더를 사용할 수 없습니다. 현재 적용: 끔") }
        if enhancementBudget.isLimited { return SPText("\(enhancementBudget.limitationDescription) 현재 적용: \(effectiveEnhancementMode.label)") }
        if effectiveEnhancementMode == .off { return SPText("현재 적용: 끔 · 자연스럽게는 영상을 확대할 때 적용됩니다. 선명하게·뭉개짐 완화는 모든 크기에 적용합니다.") }
        return SPText("현재 적용: \(effectiveEnhancementMode.label)") + (effectiveEdgeUpscaling ? SPText(" · 윤곽 확대") : "") +
            (lowResolutionEnhancement ? " · \(lowResolutionStatus)" : "")
    }
    private let mailbox: PreparedFrameMailbox
    private var displayed: ScheduledFrame?
    private var lastSubmittedFrame: ScheduledFrame?
    private var minimumVisibleTime: Double?
    private var rejectedObsoleteFrames = 0
    private var producer: Task<Void, Never>?
    private var epoch = 0
    private var previousTime = -1.0
    private var lastPresentedTime = -1.0
    private var lastRenderedSize = CGSize.zero
    private var lastBilledAudioTime: Double?
    private var hasGeneratedOutput = false
    private var closed = false
    private var presentationSuppressed = false
    private var userPaused = false
    private var refreshQueued = false
    private var priming = false
    private var displayTarget: (hostTime: Double, interval: Double)?
    private(set) var captureHostTime: Double?
    private var previousObservedTime: Double?
    /// Enter through MTKView.draw so it obtains and retires its own drawable normally.
    func draw(_ view: MTKView, at targetHostTime: Double, interval: Double) {
        // One extra refresh gives queued Metal work time to finish. The picture
        // is sampled for that same future audio instant, preserving A/V alignment.
        displayTarget = (targetHostTime + interval, interval)
        defer { displayTarget = nil }
        view.draw()
    }
    private func presentationSample() -> VideoPresentationClock.Sample {
        let before = CACurrentMediaTime()
        let mediaTime = currentTime()
        let hostTime = (before + CACurrentMediaTime()) / 2
        // TV captures the current refresh, without the local drawable's future
        // lead. Callback/drawable-wait jitter must not alternate source slots.
        let target = displayTarget.map { localVideoHidden ? $0.hostTime - 2 * $0.interval : $0.hostTime }
        let sample = VideoPresentationClock.sample(mediaTime: mediaTime, sampledHostTime: hostTime,
            targetHostTime: target, interval: displayTarget?.interval ?? 0, playing: isPlaying(),
            advanceLateTarget: !localVideoHidden)
        captureHostTime = localVideoHidden ? sample.hostTime : nil
        if let target = sample.hostTime, let mediaTimeAtHostTime {
            return .init(mediaTime: mediaTimeAtHostTime(target), hostTime: localVideoHidden ? nil : target, observedMediaTime: mediaTime)
        }
        if localVideoHidden { return .init(mediaTime: sample.mediaTime, hostTime: nil, observedMediaTime: mediaTime) }
        return sample
    }
    private func deliverOwnFrame(_ frame: ScheduledFrame, mediaTime: Double, captureReference: Double?) {
        if localVideoHidden, !ordinary, isPlaying(), let captureReference {
            // Preserve the audio-master time of EACH prepared slot, including a
            // slot recovered after a delayed UI callback. Submission time is not
            // capture time; retiming a catch-up burst would create a TV hitch.
            captureHostTime = captureReference + frame.dueTime - mediaTime
        }
        onOwnVideoFrame?(frame.pixels, frame.transform, frame.time, frame.generated)
        #if DEBUG || SMOOTH_TEST_HOST
        if localVideoHidden, let captureHostTime {
            onRemoteDeliveryForTesting?([CACurrentMediaTime(), mediaTime, frame.time,
                frame.generated ? 1 : 0, frame.dueTime, captureHostTime,
                mediaTimeAtHostTime?(captureHostTime) ?? -1])
        }
        #endif
    }
    /// Buffering and temporary preparation pauses must keep their display clock.
    func setUserPaused(_ paused: Bool) {
        guard paused != userPaused else { return }
        userPaused = paused
        refreshDisplayClock()
        requestPausedDraw()
    }
    private func refreshDisplayClock() {
        let paused = closed || presentationSuppressed || (userPaused && !localVideoHidden)
        if let clock = view as? any PresentationClockControl { clock.setPresentationClockPaused(paused) }
        else { view?.isPaused = paused }
    }
    private func invalidatePicture() {
        lastRenderedSize = .zero
        requestPausedDraw()
    }
    private func requestPausedDraw() {
        guard userPaused, !localVideoHidden, !presentationSuppressed, !closed, view != nil, !refreshQueued else { return }
        refreshQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            guard self.userPaused, !self.localVideoHidden, !self.presentationSuppressed, !self.closed else { return }
            self.view?.draw()
        }
    }
    private var renderCPUSeconds = 0.0
    private var renderGPUSeconds = 0.0
    private var renderedCommands = 0
    private var directQualityRenderCommands = 0
    private var qualityRenderCommands = 0
    private var hiddenLocalClearCommands = 0
    private var reusedPausedDraws = 0
    private var reusedHeldDraws = 0
    private var drawableWaitSeconds = 0.0
    private var backwardClockResets = 0
    private var forwardClockResets = 0
    private var maximumClockBackstep = 0.0
    private var previousPresentationClock: Double?
    private var previousPresentationMediaTime: Double?
    private weak var view: MTKView?
    private(set) var presentedGeneratedFrames = 0
    private(set) var missedPresentationDeadlines = 0
    private(set) var presentedUniqueFrames = 0
    private(set) var unpresentedDrawables = 0
    private(set) var ordinaryFallbackDraws = 0
    private(set) var maximumPresentedFrameAge = 0.0
    private(set) var lastError: String?
    var onFailure: ((String) -> Void)?
    var onPresentedSmoothInterval: ((Double) -> Void)?
    var onOpaquePresentationChanged: ((Bool) -> Void)?
    var onOwnVideoFrame: ((CVPixelBuffer, CGAffineTransform, Double, Bool) -> Void)?
    #if DEBUG || SMOOTH_TEST_HOST
    // Test observation only; release playback does not collect a presentation trace.
    var onPresentationForTesting: ((Double, Double, Bool) -> Void)?
    var onFallbackForTesting: (([String: Double]) -> Void)?
    var onSelectionForTesting: (([Double]) -> Void)?
    var onPresentationDetailsForTesting: (([Double]) -> Void)?
    /// Remote source delivery, distinct from presentation of the covered local drawable.
    var onRemoteDeliveryForTesting: (([Double]) -> Void)?
    private(set) var presentationFeedbackForTesting: (@Sendable (Double) -> Void)?
    private func recordSelection(_ shown: ScheduledFrame, sample: VideoPresentationClock.Sample, fallback: Bool) {
        onSelectionForTesting?([CACurrentMediaTime(), sample.mediaTime, shown.dueTime, shown.time,
            shown.generated ? 1 : 0, fallback ? 1 : 0, sample.hostTime ?? -1,
            shown.sceneCutHold ? 1 : 0, shown.holdUntil ?? -1])
    }
    #endif
    private(set) var outputFramesPerSecond: Double
    #if DEBUG || SMOOTH_PLAYBACK_DIAGNOSTICS
    /// Numeric snapshots for an explicitly built local diagnosis app. No frame
    /// callback, new GPU work or inference await is added to normal playback.
    var presentationDiagnostics: [String: Double] {
        let queue = mailbox.metrics()
        return ["smoothMissedDeadlines": Double(missedPresentationDeadlines),
                "smoothHeldDraws": Double(reusedHeldDraws),
                "smoothPausedDraws": Double(reusedPausedDraws),
                "smoothRenderedCommands": Double(renderedCommands),
                "smoothUnpresentedDrawables": Double(unpresentedDrawables),
                "smoothQueuedFrames": queue["queuedFrames"] ?? 0,
                "smoothProducerLeadSeconds": queue["producerLeadSeconds"] ?? 0,
                "smoothProducerResyncs": queue["lateProducerResyncs"] ?? 0,
                "smoothClockBacksteps": Double(backwardClockResets),
                "smoothClockForwardResets": Double(forwardClockResets),
                "smoothLastFrameTime": lastSubmittedFrame?.time ?? -1,
                "smoothLastFrameGenerated": lastSubmittedFrame?.generated == true ? 1 : 0]
    }
    #endif
    private var maximumBufferedFrames: Int { Int(outputFramesPerSecond / 5) }
    func generationDiagnostics() async -> [String: Double] {
        var report = await source.diagnosticMetrics()
        report["renderCPUSeconds"] = renderCPUSeconds
        report["renderGPUSeconds"] = renderGPUSeconds
        report["renderedCommands"] = Double(renderedCommands)
        report["unpresentedDrawables"] = Double(unpresentedDrawables)
        report["directQualityRenderCommands"] = Double(directQualityRenderCommands)
        report["qualityRenderCommands"] = Double(qualityRenderCommands)
        report["hiddenLocalClearCommands"] = Double(hiddenLocalClearCommands)
        report["reusedPausedDraws"] = Double(reusedPausedDraws)
        report["reusedHeldDraws"] = Double(reusedHeldDraws)
        report["drawableWaitSeconds"] = drawableWaitSeconds
        report["preparationBatchSize"] = Double(preparationBatchSize)
        report.merge(mailbox.metrics()) { _, current in current }
        report["shownAgeSeconds"] = displayed.map { currentTime() - $0.time } ?? 0
        report["backwardClockResets"] = Double(backwardClockResets)
        report["forwardClockResets"] = Double(forwardClockResets)
        report["maximumClockBackstep"] = maximumClockBackstep
        report["rejectedObsoleteFrames"] = Double(rejectedObsoleteFrames)
        return report
    }

    convenience init(player: AVPlayer, source: MovieFrameInterpolator, outputFramesPerSecond: Int = 60) throws {
        try self.init(source: source, outputFramesPerSecond: outputFramesPerSecond,
                      currentTime: { player.currentTime().seconds }, isPlaying: { player.rate > 0 })
    }

    init(source: any VideoFrameSource, outputFramesPerSecond: Int = 60, ordinary: Bool = false,
         preparationBatchSize: Int = 1,
         ordinaryFrame: (@MainActor (Double) -> DecodedVideoFrame?)? = nil,
         fallbackFrame: (@MainActor (Double) -> DecodedVideoFrame?)? = nil,
         ordinaryTransform: CGAffineTransform = .identity,
         currentTime: @escaping @MainActor () -> Double,
         mediaTimeAtHostTime: (@MainActor (Double) -> Double)? = nil,
         isPlaying: @escaping @MainActor () -> Bool) throws {
        guard [30, 60, 120].contains(outputFramesPerSecond) else { throw FrameGenerationError.invalidPrediction }
        self.outputFramesPerSecond = Double(outputFramesPerSecond)
        mailbox = PreparedFrameMailbox(rate: Double(outputFramesPerSecond))
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else { throw FrameGenerationError.missingMetal }
        self.currentTime = currentTime
        self.mediaTimeAtHostTime = mediaTimeAtHostTime
        self.isPlaying = isPlaying
        self.ordinary = ordinary
        self.preparationBatchSize = min(2, max(1, preparationBatchSize))
        self.ordinaryFrame = ordinaryFrame
        self.fallbackFrame = fallbackFrame
        self.ordinaryTransform = ordinaryTransform
        self.source = source
        self.device = device
        self.commands = commands
        enhancer = VideoEnhancer(device: device, workingSpace: .sRGB)
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        super.init()
    }

    func attach(_ view: MTKView) {
        self.view = view
        view.device = device
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        #if os(macOS)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = CGColor(gray: 0, alpha: 0)
        #else
        view.isOpaque = false
        view.layer.isOpaque = false
        view.backgroundColor = .clear
        #endif
        view.preferredFramesPerSecond = Int(outputFramesPerSecond)
        view.autoResizeDrawable = true
        view.enableSetNeedsDisplay = false
        view.delegate = self
        refreshDisplayClock()
        invalidatePicture()
    }

    /// An opaque generated surface already contains the original video. Stop the hidden
    /// ordinary surface's GPU work, and resume it when transparent fallback is required.
    func setPresentationSuppressed(_ suppressed: Bool) {
        guard presentationSuppressed != suppressed else { return }
        presentationSuppressed = suppressed
        refreshDisplayClock()
        if !suppressed { invalidatePicture() }
    }

    func setOrdinaryPresentationRate(_ framesPerSecond: Int) {
        guard ordinary, [30, 60, 120].contains(framesPerSecond) else { return }
        outputFramesPerSecond = Double(framesPerSecond)
        view?.preferredFramesPerSecond = framesPerSecond
        refreshDisplayClock()
    }

    /// Build the initial presentation window while the audio master is paused. Without this
    /// warm-up, a cold model's first prediction can never catch an already advancing clock.
    func prime(at time: Double, maximumFrames: Int? = nil) async throws {
        guard time.isFinite, time >= 0, !closed else { throw FrameGenerationError.invalidPrediction }
        guard !priming else { throw CancellationError() }
        priming = true
        defer { priming = false; requestPausedDraw() }
        let preparationEpoch = epoch
        let previousProducer = producer
        producer = nil
        previousProducer?.cancel()
        await previousProducer?.value
        try Task.checkCancellation()
        guard !closed, epoch == preparationEpoch else { throw CancellationError() }
        resetQueue(at: time)
        // The prepared seek position is already the new clock anchor. Do not
        // discard it again on the first paused, one-shot draw.
        previousTime = time
        previousObservedTime = time
        if ordinary, let ordinaryFrame {
            if let frame = ordinaryFrame(time) { displayed = ScheduledFrame(time: frame.time, pixels: frame.pixels, generated: false, transform: ordinaryTransform) }
            return
        }
        let token = epoch
        // A paused high-resolution decoder may retain only one source pair within
        // its byte budget. Warm that pair without waiting for frames it cannot
        // admit until playback advances. Steady-state cadence/queue are unchanged.
        let primeCount = maximumFrames.map { max(1, min(maximumBufferedFrames, $0)) } ?? maximumBufferedFrames
        let request = mailbox.reservePrime(count: ordinary ? 1 : primeCount)
        for timestamp in request.times {
            try Task.checkCancellation()
            guard let prepared = try await Self.prepareFrame(from: source, at: timestamp) else { break }
            guard !closed, epoch == token else { throw CancellationError() }
            mailbox.publish([prepared], epoch: request.epoch)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { invalidatePicture() }

    func draw(in view: MTKView) {
        guard !closed, !presentationSuppressed, !priming else { return }
        let previousQuality = enhancementBudget.effective
        enhancementBudget.applyThermalLimit(ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue)
        if previousQuality != enhancementBudget.effective { lastRenderedSize = .zero }
        let playingAtEntry = isPlaying()
        // A cut/duplicate hold can reuse the last submitted immutable picture without
        // waiting for a drawable. Changed/generated frames keep the existing select-
        // after-acquisition path so this optimization cannot add an audio-clock lag.
        let beforeDrawable = presentationSample()
        let beforeDrawableTime = beforeDrawable.mediaTime
        if !ordinary, playingAtEntry, !localVideoHidden,
           beforeDrawableTime.isFinite, previousTime >= 0,
           beforeDrawableTime >= previousTime - 0.02, beforeDrawableTime - previousTime <= 0.5,
           let previous = lastSubmittedFrame, view.drawableSize == lastRenderedSize {
            func reusable(_ frame: ScheduledFrame) -> Bool {
                !frame.generated && frame.pixels === previous.pixels && frame.transform == previous.transform &&
                frame.canPresent(at: beforeDrawableTime, after: minimumVisibleTime, maximumAge: 0.05)
            }
            if let candidate = mailbox.latestDue(at: beforeDrawableTime) ?? displayed, reusable(candidate) {
                // A producer may publish between the peek and advance. Recheck the
                // selected image rather than skipping a newly available different shot.
                if let selected = mailbox.advance(to: beforeDrawableTime, playing: true) { displayed = selected }
                if let shown = displayed, reusable(shown) {
                    previousTime = beforeDrawableTime
                    previousObservedTime = beforeDrawable.observedMediaTime
                    fillQueue(at: beforeDrawableTime)
                    minimumVisibleTime = max(minimumVisibleTime ?? shown.time, shown.time)
                    lastSubmittedFrame = shown
                    #if DEBUG || SMOOTH_TEST_HOST
                    recordSelection(shown, sample: beforeDrawable, fallback: false)
                    #endif
                    onOwnVideoFrame?(shown.pixels, shown.transform, shown.time, shown.generated)
                    // This is a retained original/hold, not generated trial usage.
                    hasGeneratedOutput = false; lastBilledAudioTime = nil
                    // A deliberate no-submit interval must not look like GPU congestion
                    // when the next different image is presented.
                    previousPresentationClock = nil; previousPresentationMediaTime = nil
                    reusedHeldDraws += 1
                    return
                }
            }
        }
        // Drawable acquisition may block until the display releases a surface. Select the
        // generated frame against the audio clock *after* that wait, not an old timestamp.
        let acquisitionStarted = Date.timeIntervalSinceReferenceDate
        let preparedDrawable = ordinary || !playingAtEntry ? nil : view.currentDrawable
        if !ordinary, playingAtEntry { drawableWaitSeconds += Date.timeIntervalSinceReferenceDate - acquisitionStarted }
        let presentation = presentationSample()
        let time = presentation.mediaTime
        guard time.isFinite else { return }
        // Seek detection compares the audio clock itself. Dropping the future
        // display lead on pause is not a backward seek and must retain the picture.
        if let previousObservedTime {
            let observed = presentation.observedMediaTime
            maximumClockBackstep = max(maximumClockBackstep, previousObservedTime - observed)
            if observed < previousObservedTime - 0.02 { backwardClockResets += 1; resetQueue(at: time) }
            else if observed - previousObservedTime > 0.5 { forwardClockResets += 1; resetQueue(at: time) }
        }
        previousTime = time
        previousObservedTime = presentation.observedMediaTime
        if ordinary, let ordinaryFrame, let frame = ordinaryFrame(time) {
            displayed = ScheduledFrame(time: frame.time, pixels: frame.pixels, generated: false, transform: ordinaryTransform)
        }
        let captureReference = captureHostTime
        if localVideoHidden, !ordinary, playingAtEntry {
            let due = mailbox.takeDueFrames(to: time, playing: true)
            for frame in due.dropLast() where frame.canPresent(at: frame.dueTime,
                after: minimumVisibleTime, maximumAge: 0.05) {
                minimumVisibleTime = max(minimumVisibleTime ?? frame.time, frame.time)
                deliverOwnFrame(frame, mediaTime: time, captureReference: captureReference)
            }
            if let selected = due.last { displayed = selected }
        } else if let selected = mailbox.advance(to: time, playing: isPlaying()) { displayed = selected }
        if let shown = displayed, isPlaying(), time - shown.freshnessTime > (ordinary ? 0.15 : 2 / outputFramesPerSecond) {
            missedPresentationDeadlines += 1
        }
        fillQueue(at: time)
        // Ordinary video may repeat a source frame over several display ticks. Keep the already
        // presented drawable instead of rerendering identical pixels underneath interpolation.
        if ordinary, let shown = displayed, shown.time == lastPresentedTime,
           view.drawableSize == lastRenderedSize { return }
        if !playingAtEntry, !isPlaying(), !ordinary,
           let shown = displayed, let previous = lastSubmittedFrame,
           shown.pixels === previous.pixels, shown.time == previous.time, shown.transform == previous.transform,
           view.drawableSize == lastRenderedSize {
            // Keep source delivery alive for paused TV heartbeats/refreshes. No
            // presentation or trial interval is invented for this reused image.
            onOwnVideoFrame?(previous.pixels, previous.transform, previous.time, previous.generated)
            reusedPausedDraws += 1
            return
        }
        let drawableStarted = Date.timeIntervalSinceReferenceDate
        guard let drawable = preparedDrawable ?? view.currentDrawable,
              let command = commands.makeCommandBuffer() else { return }
        if ordinary { drawableWaitSeconds += Date.timeIntervalSinceReferenceDate - drawableStarted }
        // Transparent fallback reveals AVKit's original frame underneath while warming up or
        // missing the audio-clock deadline. Never freeze the picture behind continuing audio.
        let timely = displayed.flatMap { frame -> ScheduledFrame? in
            if frame.canPresent(at: time, after: minimumVisibleTime, maximumAge: ordinary ? .infinity : 0.05) { return frame }
            if let minimumVisibleTime, frame.time + 0.000_001 < minimumVisibleTime { rejectedObsoleteFrames += 1 }
            return nil
        }
        let fallback = timely == nil ? fallbackFrame?(time) : nil
        let original = fallback.flatMap { frame -> ScheduledFrame? in
            let candidate = ScheduledFrame(time: frame.time, pixels: frame.pixels, generated: false, transform: ordinaryTransform)
            return candidate.canPresent(at: time, after: minimumVisibleTime, maximumAge: .infinity) ? candidate : nil
        }
        // If the decoder has no newer original yet, retain the last accepted picture;
        // revealing an older underlying surface would also rewind across a cut.
        let visible = timely ?? original ?? (fallbackFrame != nil ? lastSubmittedFrame : nil)
        let usingFallback = timely == nil
        guard let shown = visible else {
            if !ordinary, fallbackFrame == nil { minimumVisibleTime = max(minimumVisibleTime ?? time, time) }
            onOpaquePresentationChanged?(false)
            if isPlaying() { ordinaryFallbackDraws += 1 }
            lastBilledAudioTime = nil
            hasGeneratedOutput = false
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            if let target = presentation.hostTime { command.present(drawable, atTime: target) }
            else { command.present(drawable) }
            command.commit()
            return
        }
        if usingFallback {
            if isPlaying() { ordinaryFallbackDraws += 1 }
            #if DEBUG || SMOOTH_TEST_HOST
            if isPlaying() {
                onFallbackForTesting?(["clock": time, "shownTime": shown.time,
                    "heldTime": displayed?.time ?? -1, "holdUntil": displayed?.holdUntil ?? -1,
                    "expiredCut": displayed?.sceneCutHold == true ? 1 : 0,
                    "freshOriginal": original != nil ? 1 : 0])
            }
            #endif
            lastBilledAudioTime = nil
            hasGeneratedOutput = false
        }
        #if DEBUG || SMOOTH_TEST_HOST
        recordSelection(shown, sample: presentation, fallback: usingFallback)
        #endif
        onOpaquePresentationChanged?(true)
        minimumVisibleTime = max(minimumVisibleTime ?? shown.time, shown.time)
        lastSubmittedFrame = shown
        deliverOwnFrame(shown, mediaTime: time, captureReference: captureReference)
        lastRenderedSize = view.drawableSize
        let renderStarted = Date.timeIntervalSinceReferenceDate
        if localVideoHidden {
            // Preserve drawable presentation callbacks/cadence and source-frame
            // delivery, but do not enhance a picture covered by the remote UI.
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            effectiveEnhancementMode = .off; effectiveEdgeUpscaling = false
            hiddenLocalClearCommands += 1
        } else {
            let transformed = CIImage(cvPixelBuffer: shown.pixels).transformed(by: shown.transform)
            let image = transformed.transformed(by: CGAffineTransform(translationX: -transformed.extent.minX, y: -transformed.extent.minY))
            let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let videoRect = enhancer.presentationRectangle(videoScaleMode.rectangle(source: image.extent.size, canvas: size),
                                                          mode: enhancementBudget.effective)
            let outputSize = videoRect.size
            let eligible = lowResolutionEnhancement && (lowResolutionSource.map { $0.status(texture: image.extent.size, output: outputSize, outputFPS: outputFramesPerSecond) == nil } ?? false)
            enhancementBudget.lowResolutionRequested = lowResolutionEnhancement && eligible
            let limited = enhancementBudget.lowResolutionLimited || enhancementBudget.isLimited
            let sd = lowResolutionEnhancement && !limited ? lowResolutionSource : nil
            let enhanced = enhancer.render(image: image, targetSize: outputSize, mode: enhancementBudget.effective,
                edgeAdaptive: budgetAllowsEdgeUpscaling, lowResolution: sd, outputFPS: outputFramesPerSecond)
            lowResolutionStatus = enhanced.lowResolutionApplied ? SPText("저해상도 보정 적용 중") :
                (limited ? SPText("재생 성능을 위해 기본 보정 사용") :
                    (lowResolutionSource?.status(texture: image.extent.size, output: outputSize, outputFPS: outputFramesPerSecond) ?? SPText("영상 정보 미확인 · 기본 보정")))
            effectiveEdgeUpscaling = enhanced.edgeAdaptiveApplied
            effectiveEnhancementMode = enhanced.applied ? enhancementBudget.effective : .off
            let direct = enhancer.present(image: image, output: enhanced, mode: enhancementBudget.effective,
                                 in: videoRect, to: drawable.texture, context: context, command: command)
            if direct { directQualityRenderCommands += 1 }
            else {
                let picture = enhancer.compose(enhanced.image, in: videoRect, canvasSize: size)
                context.render(picture, to: drawable.texture, commandBuffer: command, bounds: CGRect(origin: .zero, size: size),
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            if enhanced.applied { qualityRenderCommands += 1 }
        }
        renderCPUSeconds += Date.timeIntervalSinceReferenceDate - renderStarted
        renderedCommands += 1
        let token = epoch
        let playing = isPlaying()
        let generated = shown.generated
        let frameTime = shown.time
        #if DEBUG || SMOOTH_TEST_HOST
        let dueTime = shown.dueTime
        #endif
        // Producer lateness is known when selecting the picture. Measuring it in
        // the presentation callback also charges normal GPU/display buffering as
        // producer delay, eventually reducing enhancement despite an on-time queue.
        // Actual presentation stalls are still measured by cadenceDelay below.
        let sourceDelay = ordinary ? 0 : max(0, time - shown.freshnessTime - 2 / outputFramesPerSecond) * 1_000
        let sceneCutHold = shown.sceneCutHold
        command.addCompletedHandler { [weak self] command in
            let milliseconds = max(0, command.gpuEndTime - command.gpuStartTime) * 1_000
            Task { @MainActor in
                guard let self, !self.closed, self.epoch == token else { return }
                self.renderGPUSeconds += milliseconds / 1_000
            }
        }
        let didPresent: @Sendable (Double) -> Void = { [weak self] presentationClock in
            Task { @MainActor in
                guard let self, !self.closed, self.epoch == token else { return }
                // Metal reports zero when this drawable was dropped or never
                // displayed. Count it separately; it is not display feedback,
                // a quality-budget sample or consumed generated playback.
                guard presentationClock.isFinite, presentationClock > 0 else {
                    self.unpresentedDrawables += 1
                    // A held picture cannot reuse a submission that never became
                    // visible. Let the next scheduled draw submit it again.
                    self.lastRenderedSize = .zero
                    return
                }
                #if DEBUG || SMOOTH_TEST_HOST
                self.onPresentationForTesting?(presentationClock, frameTime, generated)
                self.onPresentationDetailsForTesting?([presentationClock, frameTime, dueTime,
                    generated ? 1 : 0, sceneCutHold ? 1 : 0, usingFallback ? 1 : 0, time])
                #endif
                if frameTime != self.lastPresentedTime { self.presentedUniqueFrames += 1 }
                let presentedAudioTime = self.currentTime()
                if playing, self.isPlaying(), presentedAudioTime.isFinite {
                    self.maximumPresentedFrameAge = max(self.maximumPresentedFrameAge, max(0, presentedAudioTime - frameTime))
                }
                // Command GPU duration includes contention and does not by itself mean a
                // displayed frame was late. Preserve enhancement when actual cadence holds.
                let nominalInterval = 1 / self.outputFramesPerSecond
                let expectedInterval = self.ordinary
                    ? max(nominalInterval, frameTime - (self.previousPresentationMediaTime ?? frameTime))
                    : nominalInterval
                let cadenceDelay = self.previousPresentationClock.map {
                    max(0, presentationClock - $0 - expectedInterval) * 1_000
                } ?? 0
                let previousQuality = self.enhancementBudget.effective
                self.enhancementBudget.observe(delayMilliseconds: max(cadenceDelay, sourceDelay), refreshRate: self.outputFramesPerSecond,
                    thermalLimited: ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
                    stable: playing && self.isPlaying() && presentationClock.isFinite)
                if previousQuality != self.enhancementBudget.effective { self.lastRenderedSize = .zero }
                self.previousPresentationClock = presentationClock
                self.previousPresentationMediaTime = frameTime
                if generated, frameTime != self.lastPresentedTime {
                    self.presentedGeneratedFrames += 1
                    self.hasGeneratedOutput = true
                }
                self.lastPresentedTime = frameTime
                if sceneCutHold || usingFallback { self.hasGeneratedOutput = false; self.lastBilledAudioTime = nil }
                if !sceneCutHold, !usingFallback, playing, self.isPlaying(), self.hasGeneratedOutput {
                    if let previous = self.lastBilledAudioTime, time > previous {
                        // Charge only the visible generated-output window, excluding buffering,
                        // paused frames, seeks and transparent ordinary-video fallback.
                        self.onPresentedSmoothInterval?(min(time - previous, 2 / self.outputFramesPerSecond))
                    }
                    self.lastBilledAudioTime = time
                } else { self.lastBilledAudioTime = nil }
            }
        }
        #if DEBUG || SMOOTH_TEST_HOST
        presentationFeedbackForTesting = didPresent
        #endif
        #if targetEnvironment(simulator)
        // Simulator SDK omits MTLDrawable presentation callbacks. GPU completion exercises
        // integration only; physical-device qualification uses the actual presentation event.
        command.addCompletedHandler { if $0.status == .completed { didPresent(CACurrentMediaTime()) } }
        #else
        drawable.addPresentedHandler { didPresent($0.presentedTime) }
        #endif
        if let target = presentation.hostTime { command.present(drawable, atTime: target) }
        else { command.present(drawable) }
        command.commit()
    }

    func close() {
        guard !closed else { return }
        onOpaquePresentationChanged?(false)
        closed = true
        epoch += 1
        producer?.cancel()
        producer = nil
        refreshDisplayClock()
        view?.delegate = nil
        mailbox.close()
        displayed = nil
        lastSubmittedFrame = nil
        minimumVisibleTime = nil
        lastBilledAudioTime = nil
        Task { await source.close() }
    }

    private func resetQueue(at time: Double) {
        epoch += 1
        mailbox.reset(at: time)
        displayed = nil
        lastSubmittedFrame = nil
        minimumVisibleTime = nil
        lastPresentedTime = -1
        lastBilledAudioTime = nil
        hasGeneratedOutput = false
        previousPresentationClock = nil
        previousPresentationMediaTime = nil
    }

    private func fillQueue(at time: Double) {
        guard ordinaryFrame == nil, producer == nil, !closed, !priming, lastError == nil else { return }
        let mailbox = mailbox, source = source, batchSize = preparationBatchSize
        producer = Task.detached(priority: .userInitiated) { [weak self] in
            for await _ in mailbox.signals {
                if Task.isCancelled { break }
                while !Task.isCancelled, let request = mailbox.request(batchSize: batchSize) {
                    let started = Date.timeIntervalSinceReferenceDate
                    do {
                        let prepared: [ScheduledFrame?]
                        if request.times.count == 2 {
                            async let first = Self.prepareFrame(from: source, at: request.times[0])
                            async let second = Self.prepareFrame(from: source, at: request.times[1])
                            let pair = try await (first, second)
                            prepared = [pair.0, pair.1]
                        } else { prepared = [try await Self.prepareFrame(from: source, at: request.times[0])] }
                        try Task.checkCancellation()
                        mailbox.publish(prepared.compactMap { $0 }, epoch: request.epoch,
                                        seconds: Date.timeIntervalSinceReferenceDate - started)
                        if prepared.allSatisfy({ $0 == nil }) { break }
                    } catch is CancellationError { return }
                    catch {
                        guard mailbox.isCurrent(request.epoch) else { continue }
                        await self?.reportPreparationFailure()
                        return
                    }
                }
            }
        }
    }

    private func reportPreparationFailure() {
        guard !closed else { return }
        lastError = SPText("프레임 생성을 계속하지 못했습니다. 일반 재생으로 돌아가 주세요.")
        onFailure?(lastError!)
    }

    private nonisolated static func prepareFrame(from source: any VideoFrameSource, at timestamp: Double) async throws -> ScheduledFrame? {
        let before = await source.generatedFrames
        guard let delivery = try await source.pixels(at: timestamp) else { return nil }
        let generated: Bool
        if let supplied = delivery.isGenerated { generated = supplied }
        else { generated = await source.generatedFrames > before }
        let frameTime: Double
        if let supplied = delivery.presentationTime { frameTime = supplied }
        else { frameTime = await source.lastFrameTimestamp ?? timestamp }
        return ScheduledFrame(time: frameTime, pixels: delivery.buffer, generated: generated,
                              transform: await source.displayTransform, sceneCutHold: delivery.isSceneCutHold,
                              scheduledTime: timestamp, holdUntil: delivery.holdUntil)
    }
}
