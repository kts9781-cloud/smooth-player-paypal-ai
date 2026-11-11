import CoreVideo
import Foundation

struct ScheduledVideoFrame: @unchecked Sendable {
    let time: Double
    let pixels: CVPixelBuffer
    let generated: Bool
    let transform: CGAffineTransform
    var sceneCutHold = false
    // The source picture's timestamp and its scheduled display slot differ for holds.
    var scheduledTime: Double? = nil
    var holdUntil: Double? = nil
    var dueTime: Double { scheduledTime ?? time }
    var freshnessTime: Double { sceneCutHold ? dueTime : time }

    func canPresent(at clock: Double, after minimumTime: Double?, maximumAge: Double) -> Bool {
        guard time.isFinite, dueTime.isFinite, clock.isFinite,
              dueTime <= clock + 0.002, clock - freshnessTime <= maximumAge else { return false }
        if sceneCutHold, let holdUntil {
            guard holdUntil.isFinite, holdUntil > time, clock < holdUntil else { return false }
        }
        // A newer ordinary fallback may already have crossed into the next shot.
        // Do not replay a late prediction from before that visible boundary.
        return minimumTime.map { time + 0.000_001 >= $0 } ?? true
    }
}

/// Immutable decoded/generated buffers cross into presentation through this bounded mailbox.
/// The producer never needs the UI executor to publish a completed inference result.
final class PreparedFrameMailbox: @unchecked Sendable {
    struct Request: Sendable { let epoch: Int; let times: [Double] }
    private let lock = NSLock()
    private let capacity: Int
    private let rate: Double
    private var frames: [ScheduledVideoFrame] = []
    private var epoch = 0
    private var nextTime = 0.0
    private var clock = 0.0
    private var playing = false
    private var initial = true
    private var closed = false
    private var resyncs = 0
    private var batchSeconds = 0.0
    private var batches = 0
    let signals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(rate: Double) {
        self.rate = rate; capacity = Int(rate / 5)
        var continuation: AsyncStream<Void>.Continuation!
        signals = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.continuation = continuation
    }
    @discardableResult func reset(at time: Double) -> Int {
        lock.lock()
        epoch += 1; frames.removeAll(); clock = time
        nextTime = ceil(max(0, time) * rate) / rate; initial = true
        let token = epoch
        lock.unlock()
        continuation.yield(())
        return token
    }
    func reservePrime(count: Int) -> Request {
        lock.lock(); defer { lock.unlock() }
        let times = (0..<count).map { nextTime + Double($0) / rate }
        nextTime += Double(count) / rate
        return Request(epoch: epoch, times: times)
    }
    /// Inspect without consuming; the presenter reselects after any drawable wait.
    func latestDue(at time: Double) -> ScheduledVideoFrame? {
        lock.lock(); defer { lock.unlock() }
        return frames.last(where: { $0.dueTime <= time + 0.002 })
    }
    func advance(to time: Double, playing: Bool) -> ScheduledVideoFrame? {
        lock.lock()
        self.clock = time; self.playing = playing
        var selected: ScheduledVideoFrame?
        while let frame = frames.first, frame.dueTime <= time + 0.002 {
            selected = frames.removeFirst()
        }
        lock.unlock()
        continuation.yield(())
        return selected
    }
    /// A remote receiver has playout headroom: a delayed UI tick must not discard
    /// already prepared intermediate frames as local latest-picture selection does.
    func takeDueFrames(to time: Double, playing: Bool) -> [ScheduledVideoFrame] {
        lock.lock()
        self.clock = time; self.playing = playing
        var due: [ScheduledVideoFrame] = []
        while let frame = frames.first, frame.dueTime <= time + 0.002 {
            due.append(frames.removeFirst())
        }
        lock.unlock()
        continuation.yield(())
        return due
    }
    func request(batchSize: Int) -> Request? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, playing || initial, frames.count < capacity else { return nil }
        if nextTime < clock - 0.025 {
            nextTime = ceil((clock + 0.15) * rate) / rate
            resyncs += 1
        }
        var times: [Double] = []
        for _ in 0..<min(batchSize, capacity - frames.count) {
            guard nextTime <= clock + 0.2 else { break }
            times.append(nextTime); nextTime += 1 / rate
        }
        return times.isEmpty ? nil : Request(epoch: epoch, times: times)
    }
    func publish(_ values: [ScheduledVideoFrame], epoch token: Int, seconds: Double = 0) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, epoch == token else { return }
        frames.append(contentsOf: values)
        if !values.isEmpty { initial = false }
        if seconds > 0 { batchSeconds += seconds; batches += 1 }
    }
    func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && epoch == token
    }
    func metrics() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        return ["queuedFrames": Double(frames.count), "producerLeadSeconds": nextTime - clock,
                "lateProducerResyncs": Double(resyncs), "preparationBatchSeconds": batchSeconds,
                "preparationBatches": Double(batches)]
    }
    func close() {
        lock.lock(); closed = true; epoch += 1; frames.removeAll(); lock.unlock()
        continuation.finish()
    }
}
