import CoreGraphics
import CryptoKit
import Foundation
import Observation
import SmoothPlayerSubtitles

struct NativeSubtitleImage: Identifiable, @unchecked Sendable {
    let id: Int
    let rectangle: CGRect
    let image: CGImage
}
private struct NativeSubtitleSnapshot: @unchecked Sendable {
    let changed: Bool
    let images: [NativeSubtitleImage]
    let currentLineStart: Double?
}
enum NativeSubtitleError: LocalizedError {
    case unavailable, invalid, busy, decode(Int32)
    var errorDescription: String? {
        switch self {
        case .unavailable: SPText("이 자막 형식은 아직 지원하지 않습니다. 텍스트 자막을 선택해 주세요.")
        case .invalid: SPText("자막 데이터가 올바르지 않거나 너무 큽니다.")
        case .busy: SPText("자막을 변경하고 있습니다. 잠시 후 다시 시도해 주세요.")
        case .decode: SPText("자막을 표시하지 못했습니다. 다른 자막을 선택할 수 있습니다.")
        }
    }
}

/// libass/font lookup and FFmpeg subtitle parsing live on an independent actor.
/// No native pointer or borrowed bitmap crosses this actor boundary.
private actor NativeSubtitleWorker {
    private var handle: OpaquePointer?
    private let width: Int32, height: Int32
    private var generation = 0
    private var closed = false
    private struct PacketKey: Hashable { let time: Double, duration: Double; let digest: Data }
    private var seenPackets: Set<PacketKey> = []
    private var previousHandle: OpaquePointer?
    private var previousPackets: Set<PacketKey> = []
    init(width: Int, height: Int) {
        self.width = Int32(clamping: width); self.height = Int32(clamping: height)
    }
    deinit { if let handle { sp_sub_close(handle) }; if let previousHandle { sp_sub_close(previousHandle) } }
    func configure(_ track: EmbeddedSubtitleTrack?, ass: Data?, generation value: Int,
                   scale: Double, outline: Bool) throws {
        guard !closed, value >= generation else { throw CancellationError() }
        // Parse/shape into a candidate. A malformed replacement must preserve the
        // user's working track and its owned bitmap cache.
        var candidate: OpaquePointer?
        var accepted = false
        defer { if !accepted, let candidate { sp_sub_close(candidate) } }
        if track != nil || ass != nil {
            var error: Int32 = 0
            candidate = sp_sub_open(width, height, &error)
            guard candidate != nil else { throw NativeSubtitleError.decode(error) }
        }
        let result: Int32
        if let track, let candidate {
            guard track.supported, track.extraData.count <= 8_388_608 else { throw NativeSubtitleError.unavailable }
            result = track.extraData.withUnsafeBytes {
                sp_sub_set_codec(candidate, track.codecID, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count))
            }
        } else if let ass, let candidate {
            guard !ass.isEmpty, ass.count <= 8_388_608 else { throw NativeSubtitleError.invalid }
            result = ass.withUnsafeBytes { sp_sub_load_ass(candidate, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count)) }
        } else { result = 0 }
        guard result >= 0 else { throw NativeSubtitleError.decode(result) }
        if let candidate { sp_sub_set_style(candidate, scale, outline ? 1 : 0) }
        if let previousHandle { sp_sub_close(previousHandle) }
        previousHandle = handle; previousPackets = seenPackets
        handle = candidate; seenPackets = []; generation = value; accepted = true
    }
    func completeSelection(generation value: Int, success: Bool) {
        guard !closed else { return }
        if !success, value > generation { generation = value; return }
        guard value == generation else { return }
        if success { if let previousHandle { sp_sub_close(previousHandle) } }
        else {
            if let handle { sp_sub_close(handle) }
            handle = previousHandle; seenPackets = previousPackets
        }
        previousHandle = nil; previousPackets = []
    }
    func feed(_ packet: NativeSubtitlePacket, generation value: Int) throws {
        guard !closed, value == generation, let handle else { return }
        guard !packet.data.isEmpty, packet.data.count <= 8_388_608,
              packet.time.isFinite, packet.duration.isFinite,
              abs(packet.time) < 1e10, packet.duration >= 0, packet.duration < 1e10 else { throw NativeSubtitleError.invalid }
        // Some plain-text decoders issue a fresh ASS read-order on every decode.
        // Deduplicate source packets across seeks before that generated number changes.
        let key = PacketKey(time: packet.time, duration: packet.duration, digest: Data(SHA256.hash(data: packet.data)))
        if seenPackets.contains(key) { return }
        guard seenPackets.count < 100_000 else { throw NativeSubtitleError.invalid }
        let result = packet.data.withUnsafeBytes {
            sp_sub_feed(handle, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count),
                        Int64((packet.time * 1_000_000).rounded()), Int64((packet.duration * 1_000_000).rounded()))
        }
        guard result >= 0 else { throw NativeSubtitleError.decode(result) }
        seenPackets.insert(key)
    }
    func render(time: Double, generation value: Int) throws -> NativeSubtitleSnapshot? {
        guard !closed, generation == value, let handle else { return nil }
        guard time.isFinite, abs(time) < 1e10 else { throw NativeSubtitleError.invalid }
        var snapshot = sp_sub_snapshot()
        let result = sp_sub_render(handle, Int64((time * 1_000_000).rounded()), &snapshot)
        guard result >= 0 else { throw NativeSubtitleError.decode(result) }
        var images: [NativeSubtitleImage] = []
        if snapshot.changed != 0, let pointers = snapshot.images {
            for index in 0..<Int(snapshot.image_count) {
                let item = pointers[index]
                guard let pixels = item.rgba, item.width > 0, item.height > 0, item.stride == item.width * 4 else {
                    throw NativeSubtitleError.invalid
                }
                // CGDataProvider owns a copied Data buffer after libass frees its image cache.
                let bytes = Data(bytes: pixels, count: Int(item.stride) * Int(item.height))
                guard let provider = CGDataProvider(data: bytes as CFData),
                      let image = CGImage(width: Int(item.width), height: Int(item.height), bitsPerComponent: 8,
                                          bitsPerPixel: 32, bytesPerRow: Int(item.stride),
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { throw NativeSubtitleError.invalid }
                images.append(NativeSubtitleImage(id: index,
                    rectangle: CGRect(x: Int(item.x), y: Int(item.y), width: Int(item.width), height: Int(item.height)), image: image))
            }
        }
        return NativeSubtitleSnapshot(changed: snapshot.changed != 0, images: images,
                                      currentLineStart: snapshot.current_line_start_us < 0 ? nil : Double(snapshot.current_line_start_us) / 1_000_000)
    }
    func style(scale: Double, outline: Bool) {
        if !closed, let handle { sp_sub_set_style(handle, scale, outline ? 1 : 0) }
    }
    func close() {
        closed = true
        seenPackets.removeAll()
        if let handle { sp_sub_close(handle); self.handle = nil }
        if let previousHandle { sp_sub_close(previousHandle); self.previousHandle = nil }
        previousPackets = []
    }
}

@MainActor @Observable
final class NativeSubtitleController {
    let tracks: [EmbeddedSubtitleTrack]
    let canvasSize: CGSize
    private(set) var selectedTrackID: Int32?
    private(set) var externalFilename: String?
    private(set) var images: [NativeSubtitleImage] = []
    private(set) var currentLineStart: Double?
    private(set) var message: String?
    private(set) var loading = false
    @ObservationIgnored private let worker: NativeSubtitleWorker
    @ObservationIgnored private let selectTrack: @MainActor (Int32?) async throws -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var scale = 1.0
    @ObservationIgnored private var outline = true
    @ObservationIgnored private var latestTime = 0.0
    @ObservationIgnored private var renderTask: Task<Void, Never>?

    init(width: Int, height: Int, tracks: [EmbeddedSubtitleTrack],
         selectTrack: @escaping @MainActor (Int32?) async throws -> Void) {
        self.tracks = tracks; self.canvasSize = CGSize(width: width, height: height)
        worker = NativeSubtitleWorker(width: width, height: height); self.selectTrack = selectTrack
    }
    func selectEmbedded(trackID: Int32?) async throws {
        guard !closed else { throw CancellationError() }
        guard !loading else { throw NativeSubtitleError.busy }
        let track = trackID.flatMap { id in tracks.first { $0.id == id } }
        if trackID != nil, track?.supported != true { throw NativeSubtitleError.unavailable }
        loading = true; defer { loading = false; update(at: latestTime) }
        generation += 1; let token = generation
        let oldTrack = selectedTrackID, oldFile = externalFilename
        message = nil
        do {
            try await worker.configure(track, ass: nil, generation: token, scale: scale, outline: outline)
            guard !closed, generation == token else { throw CancellationError() }
            selectedTrackID = trackID; externalFilename = nil
            try await selectTrack(trackID)
            guard !closed, generation == token else { throw CancellationError() }
            await worker.completeSelection(generation: token, success: true)
            images = []; currentLineStart = nil
            update(at: latestTime)
        } catch {
            await worker.completeSelection(generation: token, success: false)
            if generation == token { selectedTrackID = oldTrack; externalFilename = oldFile; message = error.localizedDescription }
            throw error
        }
    }
    /// data must contain original UTF-8 ASS/SSA text, including style/event sections.
    func loadASS(data: Data, name: String) async throws {
        guard !closed else { throw CancellationError() }
        guard !loading else { throw NativeSubtitleError.busy }
        guard ["ass", "ssa"].contains((name as NSString).pathExtension.lowercased()) else { throw NativeSubtitleError.invalid }
        loading = true; defer { loading = false; update(at: latestTime) }
        generation += 1; let token = generation
        let oldTrack = selectedTrackID, oldFile = externalFilename
        message = nil
        do {
            try await worker.configure(nil, ass: data, generation: token, scale: scale, outline: outline)
            guard !closed, generation == token else { throw CancellationError() }
            selectedTrackID = nil
            try await selectTrack(nil)
            guard !closed, generation == token else { throw CancellationError() }
            await worker.completeSelection(generation: token, success: true)
            externalFilename = name; images = []; currentLineStart = nil; update(at: latestTime)
        } catch {
            await worker.completeSelection(generation: token, success: false)
            if generation == token { selectedTrackID = oldTrack; externalFilename = oldFile; message = error.localizedDescription }
            throw error
        }
    }
    func receive(_ packet: NativeSubtitlePacket) async {
        guard !closed, selectedTrackID == packet.trackID else { return }
        let token = generation
        do { try await worker.feed(packet, generation: token) }
        catch { if !closed, generation == token { message = error.localizedDescription; images = [] } }
    }
    func setStyle(scale: Double, outline: Bool) {
        guard !closed else { return }
        self.scale = scale.isFinite ? max(0.5, min(3, scale)) : 1; self.outline = outline
        let worker = worker, value = self.scale
        Task { await worker.style(scale: value, outline: outline); update(at: latestTime) }
    }
    func update(at time: Double) {
        guard !closed, time.isFinite else { return }
        latestTime = time
        guard !loading else { return }
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            guard let self else { return }
            defer { renderTask = nil }
            while !closed, !Task.isCancelled {
                let time = latestTime, token = generation
                do {
                    if let snapshot = try await worker.render(time: time, generation: token), !closed, token == generation {
                        if snapshot.changed { images = snapshot.images }
                        if currentLineStart != snapshot.currentLineStart { currentLineStart = snapshot.currentLineStart }
                    }
                } catch { if !closed, token == generation { message = error.localizedDescription; images = [] } }
                if time == latestTime { break }
            }
        }
    }
    func resetAfterSeek() {
        // Preserve parsed ASS events and read-order deduplication, matching Android.
        // The next render uses the new clock, so an active long cue remains available.
        images = []; currentLineStart = nil
        // A native unchanged snapshot still has images; force a fresh snapshot via style.
        setStyle(scale: scale, outline: outline)
    }
    func close() {
        guard !closed else { return }
        closed = true; generation += 1; renderTask?.cancel(); renderTask = nil
        images = []; currentLineStart = nil; selectedTrackID = nil
        let worker = worker
        Task { await worker.close() }
    }
}
