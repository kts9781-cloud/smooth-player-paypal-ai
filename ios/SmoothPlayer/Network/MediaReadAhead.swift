import Foundation

/// One bounded network request shared by speculative and demand reads. Completion
/// publishes data through a semaphore; only the decoder worker consumes it once.
final class MediaReadRequest: @unchecked Sendable {
    let offset: Int64
    let ready = DispatchSemaphore(value: 0)
    private(set) var data: Data?
    private(set) var remoteFailure: HTTPSRangeError?
    private(set) var elapsed = 0.0
    private var task: Task<Void, Never>?

    init(stream: any MediaByteStream, offset: Int64, count: Int = 1_048_576) {
        self.offset = offset
        task = Task.detached(priority: .userInitiated) { [self] in
            let start = Date.timeIntervalSinceReferenceDate
            do {
                try Task.checkCancellation()
                let bytes = try await stream.read(offset: offset, count: count)
                try Task.checkCancellation()
                data = bytes
            } catch let error as HTTPSRangeError { remoteFailure = error }
            catch { } // Keep transport errors free of URLs/credentials in diagnostics.
            elapsed = max(0, Date.timeIntervalSinceReferenceDate - start)
            ready.signal()
        }
    }
    func cancel() { task?.cancel() }
}

/// Bounded compressed-byte reserve, independent of the much larger decoded-pixel
/// buffer. HTTP video can keep several ranges ahead to absorb CDN latency spikes;
/// serialized NAS transports and audio retain the one-request default.
final class MediaReadAhead: @unchecked Sendable {
    private let stream: any MediaByteStream
    private let lock = NSLock()
    private var maximumWindows: Int
    private var windowBytes: Int
    private var pending: [Int64: MediaReadRequest] = [:]
    private var closed = false
    init(stream: any MediaByteStream, maximumWindows: Int = 1, windowBytes: Int = 1_048_576) {
        self.stream = stream
        self.windowBytes = min(8 * 1_048_576, max(1_048_576, windowBytes))
        self.maximumWindows = min(8 * 1_048_576 / self.windowBytes, max(1, maximumWindows))
    }

    /// Called after the demuxer identifies high-resolution video. Probes and
    /// lower-bitrate sources keep small reads that finish on slow connections.
    func configure(maximumWindows: Int, windowBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        pending.values.forEach { $0.cancel() }; pending.removeAll()
        self.windowBytes = min(8 * 1_048_576, max(1_048_576, windowBytes))
        self.maximumWindows = min(8 * 1_048_576 / self.windowBytes, max(1, maximumWindows))
    }

    func prefetch(at offset: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, offset >= 0, offset < stream.size else { return }
        for index in 0..<maximumWindows {
            let position = offset.addingReportingOverflow(Int64(index * windowBytes))
            guard !position.overflow, position.partialValue < stream.size else { break }
            let next = position.partialValue
            if pending[next] == nil, pending.count < maximumWindows {
                pending[next] = MediaReadRequest(stream: stream, offset: next, count: windowBytes)
            }
        }
    }
    func take(at offset: Int64) -> MediaReadRequest? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        if let request = pending.removeValue(forKey: offset) { return request }
        // A nonsequential demand must never retain speculative bytes for an old
        // position. The decoder also explicitly discards on seek.
        pending.values.forEach { $0.cancel() }; pending.removeAll()
        return nil
    }
    func discard() {
        lock.lock(); defer { lock.unlock() }
        pending.values.forEach { $0.cancel() }; pending.removeAll()
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; pending.values.forEach { $0.cancel() }; pending.removeAll()
    }
}
