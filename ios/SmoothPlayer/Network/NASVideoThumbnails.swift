import CoreGraphics
import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import Observation
import SmoothPlayerFFmpeg

/// Keeps a visible row stable across foreground/playback changes. The request token
/// prevents a cancelled or recycled row from accepting another video's pixels.
@MainActor @Observable
final class VideoPreviewState {
    private(set) var key: String?
    private(set) var image: CGImage?
    private(set) var loading = false
    private var request = UUID()

    func load(key: String, enabled: Bool, cached: () -> CGImage?,
              fetch: () async -> CGImage?) async {
        let token = UUID()
        request = token
        loading = false
        if self.key != key {
            self.key = key
            image = nil
        }
        guard enabled, !Task.isCancelled else { return }
        if image == nil { image = cached() }
        guard image == nil else { return }
        // Disk reads normally finish before this; only slow requests need a spinner.
        let indicator = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard request == token, !Task.isCancelled else { return }
            loading = true
        }
        defer {
            indicator.cancel()
            if request == token { loading = false }
        }
        var result = await fetch()
        if result == nil, !Task.isCancelled, request == token {
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard request == token else { return }
            result = await fetch()
        }
        guard !Task.isCancelled, request == token else { return }
        image = result
    }
}

/// Bounded previews shared by NAS rows and local/network recents. Disk keys contain no paths or credentials.
final class NASVideoThumbnails: @unchecked Sendable {
    static let shared = NASVideoThumbnails(diskDirectory: URL.cachesDirectory.appending(path: "video-previews-v2", directoryHint: .isDirectory))
    static let memoryLimit = 8 * 1024 * 1024
    static let readLimit = 32 * 1024 * 1024
    static let lifetime: TimeInterval = 24 * 60 * 60
    private struct Saved { let image: CGImage; let date: Date; let cost: Int }
    private let cacheWorker = DispatchQueue(label: "com.nodelabs.smoothplayer.preview-cache", qos: .userInitiated)
    private let worker = DispatchQueue(label: "com.nodelabs.smoothplayer.nas-preview", qos: .utility)
    private let lock = NSLock()
    private var cache: [String: Saved] = [:]
    private var order: [String] = []
    private var cost = 0
    private var generation = 0
    private var pending: [UUID: ThumbnailRequest] = [:]
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let disk: VideoPreviewDiskCache?
    private let diagnostic: @Sendable (String) -> Void
    private let openStream: @Sendable (NASConnection, NASEntry) async throws -> NASFileStream
    init(diskDirectory: URL? = nil, diagnostic: @escaping @Sendable (String) -> Void = { _ in }, openStream: @escaping @Sendable (NASConnection, NASEntry) async throws -> NASFileStream = { connection, entry in
        let client = try await NASClient.connect(connection)
        return try await client.openPreview(entry)
    }) { self.diagnostic = diagnostic; self.openStream = openStream; self.disk = diskDirectory.map { VideoPreviewDiskCache(directory: $0) } }

    static func key(connection: NASConnection, entry: NASEntry) -> String {
        NASPreviewIdentity.key(connection: connection, entry: entry)
    }
    func preserveCachedPreviews(_ migrations: [String: String]) {
        guard !migrations.isEmpty else { return }
        cacheWorker.async { [self] in
            for (old, new) in migrations { disk?.copy(from: old, to: new) }
        }
    }
    static func isVideo(_ entry: NASEntry) -> Bool {
        !entry.isDirectory && Set(["mp4", "m4v", "mov", "mkv", "avi", "ts", "m2ts", "mts", "webm", "wmv", "asf", "flv", "mpg", "mpeg", "m2v", "vob", "ogv", "3gp"]).contains((entry.name as NSString).pathExtension.lowercased())
    }
    func clear() {
        try? eraseAll()
    }
    func eraseAll() throws {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll(); order.removeAll(); cost = 0; generation += 1
        pending.values.forEach { $0.cancel() }
        try disk?.erase()
    }
    /// Backgrounding / memory pressure must not delete persistent previews.
    func clearMemory() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll(); order.removeAll(); cost = 0
    }
    /// Starting playback stops background preview work without discarding completed images.
    func cancelPending() {
        lock.lock()
        generation += 1
        let requests = Array(pending.values)
        lock.unlock()
        requests.forEach { $0.cancel() }
    }
    func cached(key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let saved = cache[key] else { return nil }
        guard Date().timeIntervalSince(saved.date) < Self.lifetime else {
            cache.removeValue(forKey: key); order.removeAll { $0 == key }; cost -= saved.cost
            return nil
        }
        order.removeAll { $0 == key }; order.append(key)
        return saved.image
    }
    private func save(_ image: CGImage, key: String, generation expected: Int, persist: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected else { return false }
        if let old = cache.removeValue(forKey: key) { cost -= old.cost }
        order.removeAll { $0 == key }
        let bytes = image.bytesPerRow * image.height
        cache[key] = Saved(image: image, date: .now, cost: bytes); order.append(key); cost += bytes
        while cost > Self.memoryLimit, let oldest = order.first {
            order.removeFirst()
            if let old = cache.removeValue(forKey: oldest) { cost -= old.cost }
        }
        if persist { disk?.save(image, key: key) }
        return true
    }
    private func register(_ request: ThumbnailRequest, id: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        pending[id] = request
        return generation
    }
    func load(connection: NASConnection, entry: NASEntry) async -> CGImage? {
        guard Self.isVideo(entry), !Task.isCancelled else { return nil }
        let key = Self.key(connection: connection, entry: entry)
        return await enqueue(key: key) { request in
            self.extract(connection: connection, entry: entry, request: request)
        }
    }
    /// Uses the same decoder/selection/cache for local MKV, AVI, MP4, etc.
    /// The caller holds the security-scoped resource for this operation.
    func load(url: URL, identity: UUID) async -> CGImage? {
        guard url.isFileURL, !Task.isCancelled else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let fields = ["local-preview-v2", identity.uuidString, url.absoluteString,
                      String(values.fileSize ?? 0), String(values.contentModificationDate?.timeIntervalSince1970 ?? 0)]
        let key = SHA256.hash(data: Data(fields.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
        return await enqueue(key: key) { request in
            var error: Int32 = 0
            guard let decoder = sp_ff_open_file(url.path, 1, &error) else { return nil }
            request.attach(decoder)
            defer { request.close(decoder) }
            return self.selectImage(decoder: decoder, request: request)
        }
    }
    private func enqueue(key: String, extract: @escaping @Sendable (ThumbnailRequest) -> CGImage?) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cached(key: key) { return image }
        let request = ThumbnailRequest(), id = UUID()
        let version = register(request, id: id)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let complete: @Sendable (CGImage?) -> Void = { image in
                    self.lock.lock(); self.pending.removeValue(forKey: id); self.lock.unlock()
                    continuation.resume(returning: image)
                }
                // Disk hits must never queue behind a slow/offline NAS file.
                self.cacheWorker.async {
                    if request.isCancelled { complete(nil); return }
                    if let image = self.cached(key: key) { complete(image); return }
                    if let image = self.disk?.load(key: key) {
                        let valid = !request.isCancelled && self.save(image, key: key, generation: version, persist: false)
                        complete(valid ? image : nil); return
                    }
                    self.worker.async {
                        if request.isCancelled { complete(nil); return }
                        // Another queued request for the same file may have completed meanwhile.
                        if let image = self.cached(key: key) { complete(image); return }
                        request.begin()
                        let image = extract(request)
                        let valid = image.map { !request.isCancelled && self.save($0, key: key, generation: version, persist: true) } ?? false
                        complete(valid ? image : nil)
                    }
                }
            }
        } onCancel: { request.cancel() }
    }
    private func extract(connection: NASConnection, entry: NASEntry, request: ThumbnailRequest) -> CGImage? {
        let started = Date()
        defer { diagnostic("finished elapsed=\(Date().timeIntervalSince(started)) cancelled=\(request.isCancelled)") }
        diagnostic("opening")
        guard let stream: NASFileStream = request.wait({ [openStream] in try await openStream(connection, entry) }) else { return nil }
        diagnostic("stream ready")
        defer { Task.detached(priority: .utility) { await stream.close() } }
        let io = ThumbnailIO(stream: stream, request: request)
        defer { diagnostic("readBytes=\(io.bytesRead)") }
        var error: Int32 = 0
        guard let decoder = sp_ff_open_io(Unmanaged.passUnretained(io).toOpaque(), { opaque, bytes, count in
            guard let opaque, let bytes, count > 0 else { return -5 }
            return Unmanaged<ThumbnailIO>.fromOpaque(opaque).takeUnretainedValue().read(bytes, count: Int(count))
        }, { opaque, offset, whence in
            guard let opaque else { return -1 }
            return Unmanaged<ThumbnailIO>.fromOpaque(opaque).takeUnretainedValue().seek(offset, whence: whence)
        }, 1, &error) else { diagnostic("decoder open failed=\(error)"); return nil }
        request.attach(decoder)
        defer { request.close(decoder) }
        return selectImage(decoder: decoder, request: request)
    }
    private func selectImage(decoder: OpaquePointer, request: ThumbnailRequest) -> CGImage? {
        var info = sp_ff_info()
        guard sp_ff_get_info(decoder, &info) == 0, info.has_video != 0,
              info.width > 0, info.height > 0, Int64(info.width) * Int64(info.height) <= 8_847_360 else { return nil }
        diagnostic("decoder ready width=\(info.width) height=\(info.height) duration=\(info.duration_seconds)")
        // Seek to bounded sample positions instead of retaining the often-black opening frame.
        // Neither the whole file nor the playback decoder is used; all attempts share one deadline/read budget.
        for seconds in VideoPreviewSelection.positions(duration: info.duration_seconds) {
            guard !request.isCancelled else { return nil }
            let seekResult = sp_ff_seek(decoder, seconds)
            diagnostic("seek seconds=\(seconds) result=\(seekResult)")
            if seekResult < 0 { continue }
            for _ in 0..<250 {
                guard !request.isCancelled else { return nil }
                var frame = sp_ff_frame()
                let result = sp_ff_next(decoder, &frame)
                if result <= 0 { diagnostic("decode stopped=\(result)"); break }
                guard result == SP_FF_VIDEO else { continue }
                if let image = thumbnail(frame: frame, info: info), VideoPreviewSelection.hasVisibleContent(image) {
                    diagnostic("visible frame")
                    return image
                }
                diagnostic("dark frame")
                // A dark candidate is followed by another timestamp, not hundreds of adjacent black frames.
                break
            }
        }
        return nil
    }
    private func thumbnail(frame: sp_ff_frame, info: sp_ff_info) -> CGImage? {
            let source: CIImage
            if let pointer = frame.cv_pixelbuffer {
                source = CIImage(cvPixelBuffer: Unmanaged<CVPixelBuffer>.fromOpaque(pointer).takeUnretainedValue())
            } else if let bytes = frame.data, frame.width > 0, frame.height > 0,
                      frame.stride >= frame.width * 4, Int64(frame.data_bytes) >= Int64(frame.stride) * Int64(frame.height) {
                source = CIImage(bitmapData: Data(bytes: bytes, count: Int(frame.data_bytes)), bytesPerRow: Int(frame.stride),
                                 size: CGSize(width: Int(frame.width), height: Int(frame.height)), format: .BGRA8,
                                 colorSpace: CGColorSpaceCreateDeviceRGB())
            } else { return nil }
            let sar = info.sample_aspect_ratio.isFinite && info.sample_aspect_ratio > 0 ? min(8, max(0.125, info.sample_aspect_ratio)) : 1
            let angle = info.rotation_degrees.isFinite ? -info.rotation_degrees * .pi / 180 : 0
            var image = source.transformed(by: CGAffineTransform(scaleX: sar, y: 1)).transformed(by: CGAffineTransform(rotationAngle: angle))
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { return nil }
            image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            let scale = min(240 / extent.width, 144 / extent.height, 1)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return context.createCGImage(image, from: CGRect(origin: .zero, size: CGSize(width: floor(extent.width * scale), height: floor(extent.height * scale))), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

enum VideoPreviewSelection {
    static func positions(duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0.5 else { return [0] }
        let last = max(0, duration - min(0.25, duration / 4))
        var result: [Double] = []
        // Keep cheap/previously successful probes first, then subdivide the
        // timeline. Dark openings and one dark distant scene do not imply an
        // empty video. All attempts still share the existing time/read budget.
        let fractions = [0.5, 0.25, 0.75, 0.125, 0.375, 0.625, 0.875]
        let candidates = [min(30, max(1, duration * 0.1)), min(90, duration * 0.35), duration * 0.65]
            + fractions.map { duration * $0 } + [0]
        for candidate in candidates {
            let value = min(last, candidate)
            if !result.contains(where: { abs($0 - value) < 0.1 }) { result.append(value) }
        }
        return result
    }
    static func hasVisibleContent(_ image: CGImage) -> Bool {
        // Sample the central area so ordinary letterboxing does not reject a visible scene.
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let data = bytes.bindMemory(to: UInt8.self)
            var visible = 0, total = 0
            for y in 3..<15 { for x in 2..<30 {
                let p = (y * width + x) * 4
                let luma = (54 * Int(data[p]) + 183 * Int(data[p + 1]) + 19 * Int(data[p + 2])) / 256
                if luma > 18 { visible += 1 }
                total += 1
            } }
            return visible * 10 >= total
        }
    }
}

private final class ThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var deadline = Date.distantFuture
    private var decoder: OpaquePointer?
    func begin() { lock.lock(); deadline = Date().addingTimeInterval(20); lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled || Date() >= deadline }
    func cancel() { lock.lock(); cancelled = true; if let decoder { sp_ff_cancel(decoder) }; lock.unlock() }
    func attach(_ pointer: OpaquePointer) { lock.lock(); decoder = pointer; if cancelled { sp_ff_cancel(pointer) }; lock.unlock() }
    func close(_ pointer: OpaquePointer) { lock.lock(); decoder = nil; lock.unlock(); sp_ff_close(pointer) }
    func wait<T>(_ operation: @escaping @Sendable () async throws -> T) -> T? {
        let result = ThumbnailResult<T>()
        let task = Task.detached(priority: .utility) {
            result.value = try? await operation()
            result.ready.signal()
        }
        while result.ready.wait(timeout: .now() + .milliseconds(50)) != .success {
            if isCancelled { task.cancel(); return nil }
        }
        return isCancelled ? nil : result.value
    }
}
private final class ThumbnailResult<T>: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    var value: T?
}
private final class ThumbnailIO {
    let stream: NASFileStream
    let request: ThumbnailRequest
    private var offset: Int64 = 0
    private(set) var bytesRead = 0
    init(stream: NASFileStream, request: ThumbnailRequest) { self.stream = stream; self.request = request }
    func read(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int32 {
        guard !request.isCancelled, bytesRead < NASVideoThumbnails.readLimit else { return -5 }
        if offset >= stream.size { return 0 }
        let position = offset, length = min(count, 65_536, NASVideoThumbnails.readLimit - bytesRead)
        guard let bytes: Data = request.wait({ [stream] in try await stream.read(offset: position, count: length) }) else { return -5 }
        if !bytes.isEmpty { _ = bytes.withUnsafeBytes { memcpy(buffer, $0.baseAddress!, bytes.count) } }
        bytesRead += bytes.count; offset += Int64(bytes.count)
        return Int32(bytes.count)
    }
    func seek(_ value: Int64, whence: Int32) -> Int64 {
        guard !request.isCancelled else { return -1 }
        if whence & Int32(SP_FF_SEEK_SIZE) != 0 { return stream.size }
        let base: Int64
        switch whence & ~Int32(0x20000) { case 0: base = 0; case 1: base = offset; case 2: base = stream.size; default: return -1 }
        let next = base.addingReportingOverflow(value)
        guard !next.overflow, next.partialValue >= 0, next.partialValue <= stream.size else { return -1 }
        offset = next.partialValue; return offset
    }
}
