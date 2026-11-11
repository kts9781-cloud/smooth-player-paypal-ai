import Foundation
import SmoothPlayerNAS

private func nasError(_ status: Int32) -> NASError {
    switch status {
    case -2: return .authenticationFailed
    case -3: return .timedOut
    case -4: return .invalidPath
    case -5: return .closed
    case -6: return .limitExceeded
    case -7: return .filenameEncoding
    default: return .connectionFailed
    }
}

private final class EntryCollector {
    let parent: String
    var entries = [NASEntry]()
    init(parent: String) { self.parent = parent }
}

private final class ShareCollector { var names: [String] = [] }

/// Each native connection is serially confined. CFNetwork and libsmb2 never execute on the main thread.
final class NASClient: @unchecked Sendable {
    let connection: NASConnection
    fileprivate let queue: DispatchQueue
    private var handle: OpaquePointer?

    private init(connection: NASConnection) {
        self.connection = connection
        queue = DispatchQueue(label: "com.nodelabs.smoothplayer.nas.\(connection.id.uuidString)", qos: .userInitiated)
    }

    /// Uses the editor's unsaved credential only for this request. Nothing is persisted.
    static func listShares(_ connection: NASConnection, password: String) async throws -> [String] {
        guard connection.kind == .smb, !password.contains("\0") else { throw NASError.invalidConnection }
        var probe = connection
        probe.share = "IPC$"
        probe = try probe.validated()
        let client = NASClient(connection: probe)
        let result = try await client.perform {
            let collector = ShareCollector()
            let status = sp_nas_list_shares(probe.host, probe.port, probe.username, password, probe.domain, 8, { context, name in
                guard let context, let name else { return }
                Unmanaged<ShareCollector>.fromOpaque(context).takeUnretainedValue().names.append(String(cString: name))
            }, Unmanaged.passUnretained(collector).toOpaque())
            guard status == 0 else { throw nasError(status) }
            return Array(Set(collector.names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        try Task.checkCancellation()
        return result
    }

    static func connect(_ connection: NASConnection) async throws -> NASClient {
        let password = try NASCredentialStore.password(for: connection.id)
        return try await connect(connection, password: password)
    }

    /// An explicit credential can be used for a temporary, unsaved connection.
    static func connect(_ connection: NASConnection, password: String) async throws -> NASClient {
        let connection = try connection.validated()
        guard !password.contains("\0"), connection.kind != .ftp || (!password.contains("\r") && !password.contains("\n")) else {
            throw NASError.invalidConnection
        }
        let client = NASClient(connection: connection)
        try await client.perform {
            var status: Int32 = 0
            client.handle = sp_nas_connect(connection.kind == .smb ? 1 : 2, connection.host,
                                           connection.port, connection.share, connection.username,
                                           password, connection.domain, 8, &status)
            guard let handle = client.handle else { throw nasError(status) }
            let configured = sp_nas_set_ftp_encoding(handle, connection.ftpEncoding.nativeValue)
            guard configured == 0 else { throw nasError(configured) }
        }
        try Task.checkCancellation()
        return client
    }

    deinit {
        let native = handle
        queue.async { if let native { sp_nas_disconnect(native) } }
    }

    fileprivate func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func list(path: String? = nil, encodedPath: String? = nil) async throws -> [NASEntry] {
        let path = try NASPath.normalized(path ?? connection.rootPath)
        let result = try await perform {
            guard let handle = self.handle else { throw NASError.closed }
            let collector = EntryCollector(parent: path)
            let context = Unmanaged.passUnretained(collector).toOpaque()
            let callback: sp_nas_path_entry_callback = { context, rawName, wirePath, directory, size, modified in
                guard let context, let rawName, size <= UInt64(Int64.max) else { return }
                let collector = Unmanaged<EntryCollector>.fromOpaque(context).takeUnretainedValue()
                let name = String(cString: rawName)
                guard let path = try? NASPath.child(name, of: collector.parent) else { return }
                collector.entries.append(NASEntry(path: path, name: name, isDirectory: directory != 0,
                                                  size: Int64(size), modifiedAt: modified > 0 ? Date(timeIntervalSince1970: Double(modified)) : nil,
                                                  encodedPath: wirePath.map { String(cString: $0) }))
            }
            func invoke(_ wire: UnsafePointer<CChar>?) -> Int32 { sp_nas_list_paths(handle, path, wire, callback, context) }
            let status = encodedPath.map { $0.withCString(invoke) } ?? invoke(nil)
            guard status == 0 else { throw nasError(status) }
            return collector.entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        try Task.checkCancellation()
        return result
    }

    /// Imported legacy recents contain display names without the original FTP bytes.
    /// Resolve each directory from its listing, including Korean parent folders;
    /// encoding a guessed full path as UTF-8 cannot locate a CP949 NAS filename.
    /// This is read-only and never changes the saved history or its watch position.
    func openPreview(_ entry: NASEntry) async throws -> NASFileStream {
        var resolved = entry
        if connection.kind == .ftp, entry.encodedPath == nil {
            let components = try NASPath.normalized(entry.path).split(separator: "/").map(String.init)
            guard !entry.isDirectory, !components.isEmpty else { throw NASError.invalidPath }
            var parent = "/", wireParent = "/"
            for (index, name) in components.enumerated() {
                try Task.checkCancellation()
                let children = try await list(path: parent, encodedPath: wireParent)
                let directory = index < components.count - 1
                let matches = children.filter { $0.name == name && $0.isDirectory == directory }
                // Two opaque byte sequences can have the same displayed name. Never
                // choose a similarly named file or silently guess an ambiguous match.
                guard matches.count == 1, let child = matches.first, let wire = child.encodedPath else {
                    throw NASError.invalidPath
                }
                resolved = child; parent = child.path; wireParent = wire
            }
        }
        return try await open(path: resolved.path, encodedPath: resolved.encodedPath, expectedSize: resolved.size)
    }

    func open(path: String, encodedPath: String? = nil, expectedSize: Int64? = nil) async throws -> NASFileStream {
        let path = try NASPath.normalized(path)
        let stream = try await perform {
            guard let handle = self.handle else { throw NASError.closed }
            var size: Int64 = -1
            var status: Int32 = 0
            func invoke(_ wire: UnsafePointer<CChar>?) -> OpaquePointer? { sp_nas_open_path_with_size(handle, path, wire, expectedSize.flatMap { $0 >= 0 ? $0 : nil } ?? -1, &size, &status) }
            let native = encodedPath.map { $0.withCString(invoke) } ?? invoke(nil)
            guard let file = native else { throw nasError(status) }
            return NASFileStream(client: self, handle: file, size: size)
        }
        if Task.isCancelled {
            await stream.close()
            throw CancellationError()
        }
        return stream
    }
}

/// Byte ranges are read on the connection queue, supporting AVAssetResourceLoader seeking.
/// Reads are capped at 1 MiB and may return fewer bytes; callers continue until their requested range is satisfied.
final class NASFileStream: @unchecked Sendable {
    let size: Int64
    private let client: NASClient
    private var handle: OpaquePointer?

    fileprivate init(client: NASClient, handle: OpaquePointer, size: Int64) {
        self.client = client; self.handle = handle; self.size = size
    }

    deinit {
        let native = handle
        let session = client
        session.queue.async { [session] in
            if let native { sp_nas_close(native) }
            _ = session // Keep the native client alive until its file has been closed.
        }
    }

    func read(offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, count >= 0, count <= 1_048_576 else { throw NASError.limitExceeded }
        if count == 0 || offset >= size { return Data() }
        let bytes = try await client.perform {
            guard let handle = self.handle else { throw NASError.closed }
            var output = Data(count: count)
            let size = output.withUnsafeMutableBytes { buffer in
                sp_nas_read(handle, offset, buffer.bindMemory(to: UInt8.self).baseAddress!, UInt32(count))
            }
            guard size >= 0 else { throw nasError(size) }
            output.count = Int(size)
            return output
        }
        try Task.checkCancellation()
        return bytes
    }

    func close() async {
        await withCheckedContinuation { continuation in
            client.queue.async {
                if let handle = self.handle { sp_nas_close(handle); self.handle = nil }
                continuation.resume()
            }
        }
    }
}
