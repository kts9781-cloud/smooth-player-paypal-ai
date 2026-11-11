import Combine
import Foundation

/// A current, read-only FTP listing and its live connection. This contains no
/// password string or authenticated URL and can outlive the browsing sheet.
struct MacNetworkPlaybackSelection: Sendable {
    let client: NASClient
    let entries: [NASEntry]
    let entry: NASEntry
}

@MainActor
final class MacNetworkBrowserModel: ObservableObject {
    let privacy = FolderPrivacyStore(service: MacAppStorage.privacyService)
    @Published private(set) var connections: [NASConnection] = []
    @Published private(set) var currentConnection: NASConnection?
    @Published private(set) var currentPath = "/"
    @Published private(set) var entries: [NASEntry] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private struct Location { let path: String; let encodedPath: String? }
    private var locations: [Location] = []
    private var client: NASClient?
    private var generation: UInt = 0
    private let storageURL: URL
    private var storageReadable = true

    init(storageURL: URL = MacAppStorage.file("ftp-servers.json")) {
        self.storageURL = storageURL
        do {
            guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
            let handle = try FileHandle(forReadingFrom: storageURL)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 1_048_577) ?? Data()
            guard bytes.count <= 1_048_576 else { throw MacFTPBrowserError.storage }
            let saved = try JSONDecoder().decode([NASConnection].self, from: bytes)
            guard saved.count <= 128, Set(saved.map(\.id)).count == saved.count else { throw MacFTPBrowserError.storage }
            connections = try saved.map { connection in
                return try connection.validated()
            }
        } catch {
            storageReadable = false
            errorMessage = SPText("저장된 FTP 서버 목록을 읽지 못했습니다. 기존 파일은 변경하지 않았습니다.")
        }
    }

    var canReadStorage: Bool { storageReadable }
    var canGoBack: Bool { locations.count > 1 && !isLoading }
    var visibleEntries: [NASEntry] { entries.filter { entry in
        (entry.isDirectory || MacPlayerModel.supportsVideo(entry.name)) && currentConnection.map { privacy.visible(FolderPrivacyStore.networkLocation($0, path: entry.path)) } != false
    } }
    var visibleConnections: [NASConnection] { connections.filter { privacy.visible(FolderPrivacyStore.networkLocation($0, path: $0.rootPath)) } }
    func replaceFromAccount(_ values: [(NASConnection, String)], aliases: [UUID: UUID] = [:]) throws {
        guard storageReadable else { throw MacFTPBrowserError.storage }
        let next = try values.map { (try $0.0.validated(), $0.1) }
        let old = connections
        let passwords = try Dictionary(uniqueKeysWithValues: old.map { ($0.id, try NASCredentialStore.password(for: $0.id)) })
        do {
            for (c, password) in next { try NASCredentialStore.save(password: password, for: c.id) }
            try persist(next.map(\.0))
        } catch {
            for (id, password) in passwords { try? NASCredentialStore.save(password: password, for: id) }
            for (c, _) in next where passwords[c.id] == nil { try? NASCredentialStore.delete(for: c.id) }
            throw error
        }
        connections = next.map(\.0)
        NASCredentialStore.registerAliases(aliases, validConnectionIDs: Set(connections.map(\.id)))
        for c in old where !connections.contains(where: { $0.id == c.id }) { try NASCredentialStore.delete(for: c.id) }
        if let c = currentConnection {
            if let id = aliases[c.id], let replacement = connections.first(where: { $0.id == id }) {
                currentConnection = replacement
                return // Same endpoint/credential: keep the current directory and live client.
            }
            let before = old.first { $0.id == c.id }
            let after = next.first { $0.0.id == c.id }
            if before != after?.0 || passwords[c.id] != after?.1 { close() }
        }
    }

    @discardableResult
    func save(_ connection: NASConnection, password: String) throws -> NASConnection {
        guard storageReadable else { throw MacFTPBrowserError.storage }
        var value = try connection.validated()
        value.id = NASCredentialStore.resolvedConnectionID(value.id)
        guard password.utf8.count <= 4_096,
              !password.contains("\0"), !password.contains("\r"), !password.contains("\n") else {
            throw NASError.invalidConnection
        }
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.name.isEmpty { value.name = value.host }
        guard value.name.utf8.count <= 512, value.username.utf8.count <= 512 else { throw NASError.invalidConnection }
        var next = connections
        if let index = next.firstIndex(where: { $0.id == value.id }) { next[index] = value }
        else { guard next.count < 128 else { throw NASError.limitExceeded }; next.append(value) }
        let existed = connections.contains { $0.id == value.id }
        let oldPassword = try NASCredentialStore.password(for: value.id)
        try NASCredentialStore.save(password: password, for: value.id)
        do { try persist(next) }
        catch {
            if existed { try? NASCredentialStore.save(password: oldPassword, for: value.id) }
            else { try? NASCredentialStore.delete(for: value.id) }
            throw MacFTPBrowserError.storage
        }
        connections = next
        errorMessage = nil
        return value
    }

    func password(for connection: NASConnection) throws -> String {
        guard connections.contains(where: { $0.id == connection.id }) else { throw NASError.invalidConnection }
        return try NASCredentialStore.password(for: connection.id)
    }

    /// Removes only the saved connection and its own Keychain item. No FTP file
    /// operations are exposed; an already playing stream retains its connection.
    func remove(_ connection: NASConnection) throws {
        guard storageReadable, connections.contains(where: { $0.id == connection.id }) else { return }
        let oldPassword = try NASCredentialStore.password(for: connection.id)
        try NASCredentialStore.delete(for: connection.id)
        let next = connections.filter { $0.id != connection.id }
        do { try persist(next) }
        catch {
            try? NASCredentialStore.save(password: oldPassword, for: connection.id)
            throw MacFTPBrowserError.storage
        }
        connections = next
        if currentConnection?.id == connection.id { close() }
    }

    func connect(_ connection: NASConnection) async throws {
        guard privacy.visible(FolderPrivacyStore.networkLocation(connection, path: connection.rootPath)) else { throw NASError.invalidPath }
        generation &+= 1
        let token = generation
        isLoading = true; errorMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
        if connection.kind == .smb && connection.share.isEmpty {
            let shares = try await NASClient.listShares(connection, password: NASCredentialStore.password(for: connection.id))
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            locations = []
            currentConnection = connection; currentPath = "/"; client = nil
            entries = shares.map { NASEntry(path: "/" + $0, name: $0, isDirectory: true, size: 0, modifiedAt: nil) }
            return
        }
            let candidate = try await NASClient.connect(connection)
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            let listing = try await candidate.list()
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            client = candidate; currentConnection = candidate.connection
            currentPath = candidate.connection.rootPath
            locations = [Location(path: currentPath, encodedPath: nil)]
            entries = listing
        } catch {
            guard generation == token else { throw CancellationError() }
            if !(error is CancellationError) { errorMessage = Self.message(error) }
            throw error
        }
    }

    func enter(_ entry: NASEntry) async throws {
        if var c = currentConnection, c.kind == .smb, c.share.isEmpty, entry.isDirectory {
            c.share = entry.name; c.rootPath = "/"; try await connect(c); return
        }
        guard !isLoading, entry.isDirectory, visibleEntries.contains(entry), let client else { throw NASError.invalidPath }
        let next = Location(path: entry.path, encodedPath: entry.encodedPath)
        try await list(next, client: client) { self.locations.append(next) }
    }

    func goBack() async throws {
        guard canGoBack, let client else { return }
        let previous = locations[locations.count - 2]
        try await list(previous, client: client) { self.locations.removeLast() }
    }

    func refresh() async throws {
        guard !isLoading, let client, let location = locations.last else { return }
        try await list(location, client: client) {}
    }

    func selection(for entry: NASEntry) throws -> MacNetworkPlaybackSelection {
        guard !isLoading, !entry.isDirectory, MacPlayerModel.supportsVideo(entry.name),
              visibleEntries.contains(entry), let client else { throw NASError.invalidPath }
        // The browsing list hides subtitle files. Playback still needs the
        // accessible sidecars from this directory to match them to the video.
        let playableEntries = entries.filter {
            privacy.visible(FolderPrivacyStore.networkLocation(client.connection, path: $0.path))
        }
        return MacNetworkPlaybackSelection(client: client, entries: playableEntries, entry: entry)
    }
    func selection(for video: NASRecentVideo, recents: NASRecentStore) async throws -> MacNetworkPlaybackSelection {
        let c = try recents.connection(for: video, in: connections)
        guard privacy.visible(FolderPrivacyStore.networkLocation(c, path: video.path)) else { throw NASError.invalidPath }
        let client = try await NASClient.connect(c)
        let entries = try await client.list(path: video.parentPath, encodedPath: video.parentEncodedPath)
        let entry = try recents.restoredEntry(for: video, from: entries)
        return MacNetworkPlaybackSelection(client: client, entries: entries.filter { privacy.visible(FolderPrivacyStore.networkLocation(c, path: $0.path)) }, entry: entry)
    }

    func close() {
        generation &+= 1
        client = nil; currentConnection = nil
        locations = []; entries = []; currentPath = "/"
        isLoading = false; errorMessage = nil
    }

    private func list(_ location: Location, client: NASClient, commit: () -> Void) async throws {
        generation &+= 1
        let token = generation
        isLoading = true; errorMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            let listing = try await client.list(path: location.path, encodedPath: location.encodedPath)
            try Task.checkCancellation()
            guard generation == token, self.client === client else { throw CancellationError() }
            commit(); currentPath = location.path; entries = listing
        } catch {
            guard generation == token else { throw CancellationError() }
            if !(error is CancellationError) { errorMessage = Self.message(error) }
            throw error
        }
    }

    private func persist(_ connections: [NASConnection]) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(connections)
        guard data.count <= 1_048_576 else { throw MacFTPBrowserError.storage }
        // Metadata only. Passwords remain in NASCredentialStore / Keychain.
        try data.write(to: storageURL, options: .atomic)
        // The atomic replacement has committed at this point. An unsupported
        // filesystem permission must not roll back only the matching Keychain.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    static func message(_ error: Error) -> String {
        if let error = error as? NASError { return error.localizedDescription }
        if let error = error as? MacFTPBrowserError { return error.localizedDescription }
        if error is CancellationError { return SPText("연결을 취소했습니다.") }
        return SPText("FTP 작업을 완료하지 못했습니다. 서버 주소와 네트워크를 확인해 주세요.")
    }
}

private enum MacFTPBrowserError: LocalizedError {
    case storage
    var errorDescription: String? { SPText("FTP 서버 목록을 저장하지 못했습니다. 앱 저장 공간을 확인해 주세요.") }
}
