import Foundation
import Observation

/// Resume metadata only. Host, username, password and authenticated URLs are never copied here.
struct NASRecentVideo: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var connectionID: UUID
    var path: String
    var encodedPath: String?
    var name: String
    var position: Double
    var duration: Double
    var fileSize: Int64
    var modifiedAt: Date?
    var openedAt: Date
    var share: String? = nil

    var parentPath: String { (path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent }
    var parentEncodedPath: String? {
        guard let encodedPath, let separator = encodedPath.lastIndex(of: "/") else { return nil }
        return separator == encodedPath.startIndex ? "/" : String(encodedPath[..<separator])
    }
    func matches(connectionID: UUID, entry: NASEntry) -> Bool {
        guard self.connectionID == connectionID else { return false }
        if let encodedPath { return encodedPath == entry.encodedPath }
        return path == entry.path
    }
}

enum NASResumeError: LocalizedError, Equatable {
    case serverRemoved, fileUnavailable, invalidRecord
    var errorDescription: String? {
        switch self {
        case .serverRemoved: SPText("이 영상의 서버가 삭제되었습니다. 서버를 다시 추가하고 NAS 폴더에서 영상을 선택해 주세요.")
        case .fileUnavailable: SPText("서버에서 이 파일을 찾지 못했습니다. 파일이 이동되거나 삭제되었는지 확인하고 NAS 폴더에서 다시 선택해 주세요.")
        case .invalidRecord: SPText("저장된 NAS 재생 위치를 읽지 못했습니다. NAS 폴더에서 영상을 다시 선택해 주세요.")
        }
    }
}

@MainActor @Observable
final class NASRecentStore {
    private(set) var videos: [NASRecentVideo] = []
    var errorMessage: String?
    private let storageURL: URL
    @ObservationIgnored private let persistenceQueue = DispatchQueue(label: "com.nodelabs.smoothplayer.nas-history", qos: .utility)
    @ObservationIgnored private let writeHistory: @Sendable ([NASRecentVideo], URL) throws -> Void
    @ObservationIgnored private var persistenceRevision: UInt = 0
    private var unreadableStorage = false
    #if DEBUG || SMOOTH_TEST_HOST
    @ObservationIgnored var onPersistenceForTesting: ((Double, Double) -> Void)?
    #endif
    // A playing session can still hold the original connection object after a
    // duplicate is merged. Its next save must target the surviving connection.
    private var connectionAliases: [UUID: UUID] = [:]

    private func resolvedConnectionID(_ id: UUID) -> UUID { connectionAliases[id] ?? NASCredentialStore.resolvedConnectionID(id) }

    init(storageURL: URL = URL.applicationSupportDirectory.appending(path: "nas-recent-videos.json"),
         writeHistory: (@Sendable ([NASRecentVideo], URL) throws -> Void)? = nil) {
        self.storageURL = storageURL
        self.writeHistory = writeHistory ?? { records, location in try Self.writeSnapshot(records, to: location) }
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) {
                let records = try JSONDecoder().decode([NASRecentVideo].self, from: Data(contentsOf: storageURL))
                guard records.count <= 500, Set(records.map(\.id)).count == records.count else { throw NASResumeError.invalidRecord }
                try records.forEach(Self.validate)
                videos = records.sorted { $0.openedAt > $1.openedAt }
            }
        } catch {
            unreadableStorage = true
            errorMessage = SPText("NAS 최근 목록을 읽지 못했습니다. 설정에서 최근 목록을 지운 뒤 다시 재생해 주세요.")
        }
    }

    func resumePosition(connectionID: UUID, entry: NASEntry, share: String? = nil) -> Double {
        guard let record = matching(connectionID: resolvedConnectionID(connectionID), entry: entry, share: share).first,
              record.fileSize == 0 || record.fileSize == entry.size,
              record.modifiedAt == nil || entry.modifiedAt == nil || record.modifiedAt == entry.modifiedAt,
              record.position > 0, record.duration <= 0 || record.position < record.duration - 2 else { return 0 }
        return record.position
    }

    private func matching(connectionID: UUID, entry: NASEntry, share: String?) -> [NASRecentVideo] {
        let candidates = videos.filter { $0.connectionID == connectionID && $0.path == entry.path && ($0.share == nil || $0.share == share) }
        let wires = Set(candidates.compactMap(\.encodedPath) + [entry.encodedPath].compactMap { $0 })
        return wires.count <= 1 ? candidates : candidates.filter { $0.encodedPath == entry.encodedPath }
    }

    @discardableResult
    func record(connectionID: UUID, entry: NASEntry, position: Double, duration: Double,
                completed: Bool = false, openedAt: Date = .now, share: String? = nil,
                inBackground: Bool = false) -> Bool {
        guard !unreadableStorage, !entry.isDirectory, position.isFinite, duration.isFinite,
              position >= 0, duration > 0, entry.size >= 0 else { return false }
        let connectionID = resolvedConnectionID(connectionID)
        let old = videos
        let matches = matching(connectionID: connectionID, entry: entry, share: share)
        let existing = matches.first
        let value = NASRecentVideo(id: existing?.id ?? UUID(), connectionID: connectionID,
                                   path: entry.path, encodedPath: entry.encodedPath ?? matches.compactMap(\.encodedPath).first, name: entry.name,
                                   position: completed ? 0 : min(position, duration), duration: duration,
                                   fileSize: entry.size, modifiedAt: entry.modifiedAt, openedAt: openedAt, share: share)
        do {
            try Self.validate(value)
            let replaced = Set(matches.map(\.id))
            videos.removeAll { replaced.contains($0.id) }
            videos.insert(value, at: 0)
            videos = Array(videos.prefix(500))
            try persist(inBackground: inBackground)
            errorMessage = nil
            return true
        } catch {
            videos = old
            errorMessage = SPText("NAS 재생 위치를 저장하지 못했습니다. 일반 재생은 계속할 수 있습니다.")
            return false
        }
    }

    func connection(for video: NASRecentVideo, in connections: [NASConnection]) throws -> NASConnection {
        try Self.validate(video)
        guard var connection = connections.first(where: { $0.id == video.connectionID }) else { throw NASResumeError.serverRemoved }
        if connection.kind == .smb, let share = video.share { connection.share = share }
        return connection
    }

    /// Resolve against a fresh directory listing before resuming. Stale file sizes must not be
    /// trusted as an FTP SIZE fallback, and a missing file must not open a similarly named item.
    func restoredEntry(for video: NASRecentVideo, from entries: [NASEntry]) throws -> NASEntry {
        try Self.validate(video)
        guard let entry = entries.first(where: { !$0.isDirectory && video.matches(connectionID: video.connectionID, entry: $0) }) else {
            throw NASResumeError.fileUnavailable
        }
        return entry
    }

    func remove(_ id: UUID) { updateRemoving { $0.id == id } }
    func remove(connectionID: UUID) { updateRemoving { $0.connectionID == connectionID } }
    private func updateRemoving(_ matches: (NASRecentVideo) -> Bool) {
        guard !unreadableStorage else { return }
        let old = videos
        videos.removeAll(where: matches)
        do { try persist(); errorMessage = nil }
        catch { videos = old; errorMessage = SPText("NAS 최근 항목을 지우지 못했습니다. 다시 시도해 주세요.") }
    }
    func clear() {
        do { try eraseLocalData() }
        catch { errorMessage = SPText("NAS 최근 목록을 지우지 못했습니다. 다시 시도해 주세요.") }
    }
    func eraseLocalData() throws {
        persistenceRevision &+= 1
        try persistenceQueue.sync {
            if FileManager.default.fileExists(atPath: storageURL.path) { try FileManager.default.removeItem(at: storageURL) }
        }
        videos = []; errorMessage = nil; unreadableStorage = false
    }

    private static func validate(_ record: NASRecentVideo) throws {
        guard record.path.hasPrefix("/"), try NASPath.normalized(record.path) == record.path,
              !record.name.isEmpty, record.name.utf8.count <= 4096,
              record.name == (record.path as NSString).lastPathComponent,
              !record.name.contains("/"), !record.name.contains("\\"), !record.name.contains("\0"),
              record.position.isFinite, record.duration.isFinite, record.position >= 0,
              record.duration >= 0, record.position <= record.duration, record.fileSize >= 0,
              record.openedAt.timeIntervalSince1970.isFinite else { throw NASResumeError.invalidRecord }
        if let wire = record.encodedPath {
            guard wire.hasPrefix("/"), wire.utf8.count <= 24576,
                  wire.utf8.allSatisfy({ $0 >= 0x21 && $0 < 0x7f }),
                  !wire.contains("\\"), !wire.contains("://"),
                  !wire.split(separator: "/").contains("..") else { throw NASResumeError.invalidRecord }
        }
    }
    /// Periodic checkpoints must not block display callbacks. Explicit saves,
    /// account replacement and deletion drain the same queue to preserve order.
    private func persist(inBackground: Bool = false) throws {
        #if DEBUG || SMOOTH_TEST_HOST
        let started = ProcessInfo.processInfo.systemUptime
        defer { onPersistenceForTesting?(started, ProcessInfo.processInfo.systemUptime - started) }
        #endif
        persistenceRevision &+= 1
        let revision = persistenceRevision
        let records = videos, location = storageURL, write = writeHistory
        if inBackground {
            persistenceQueue.async { [weak self] in
                let failed: Bool
                do { try write(records, location); failed = false } catch { failed = true }
                Task { @MainActor [weak self] in
                    guard let self, self.persistenceRevision == revision else { return }
                    self.errorMessage = failed ? SPText("NAS 재생 위치를 저장하지 못했습니다. 일반 재생은 계속할 수 있습니다.") : nil
                }
            }
        } else {
            try persistenceQueue.sync { try write(records, location) }
        }
    }

    nonisolated static func writeSnapshot(_ records: [NASRecentVideo], to location: URL) throws {
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = location
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    func replaceFromAccount(_ records: [NASRecentVideo], aliases: [UUID: UUID] = [:], validConnectionIDs: Set<UUID>? = nil) throws {
        guard !unreadableStorage, records.count <= 500 else { throw NASResumeError.invalidRecord }
        try records.forEach(Self.validate)
        let old = videos
        videos = records.sorted { $0.openedAt > $1.openedAt }
        do { try persist() } catch { videos = old; throw error }
        var redirects = connectionAliases.merging(aliases) { _, new in new }
        for (source, destination) in redirects { redirects[source] = aliases[destination] ?? destination }
        if let validConnectionIDs { redirects = redirects.filter { !validConnectionIDs.contains($0.key) && validConnectionIDs.contains($0.value) } }
        connectionAliases = redirects
    }
}
