import CryptoKit
import Foundation

enum NASPreviewIdentity {
    static func key(connection: NASConnection, entry: NASEntry) -> String {
        let fields = ["nas-preview-v2", connection.id.uuidString, connection.kind.rawValue, connection.host,
                      String(connection.port), connection.share, connection.username, connection.domain,
                      connection.ftpEncoding.rawValue, entry.encodedPath ?? entry.path, String(entry.size),
                      entry.modifiedAt.map { String($0.timeIntervalSince1970) } ?? ""]
        return SHA256.hash(data: Data(fields.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Re-key only identical connections and the same file revision. Existing cache bytes stay intact.
    static func migrations(from previous: [String: NASCloudValue], to next: [String: NASCloudValue]) -> [String: String] {
        let aliases = NASDuplicateMerge.aliases(from: previous, to: next)
        var result: [String: String] = [:]
        for value in previous.values {
            guard case .recent(let old) = value else { continue }
            let target = aliases[old.connectionID] ?? old.connectionID
            guard let recent = NASDuplicateMerge.replacement(for: old, connectionID: target, in: next), old.fileSize == recent.fileSize,
                  sameRevision(old.modifiedAt, recent.modifiedAt),
                  case .server(let server) = previous["server:" + old.connectionID],
                  next["server:" + target] == .server(server),
                  let sourceKey = key(server: server, recent: old), let targetKey = key(server: server, recent: recent),
                  sourceKey != targetKey else { continue }
            result[sourceKey] = targetKey
        }
        return result
    }
    private static func sameRevision(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) { case (nil, nil): true; case (.some(let a), .some(let b)): abs(a - b) < 0.001; default: false }
    }
    private static func key(server: NASCloudServer, recent: NASCloudRecent) -> String? {
        guard let id = UUID(uuidString: recent.connectionID), let kind = NASProtocol(rawValue: server.protocol),
              let port = UInt16(exactly: server.port), let encoding = FTPFilenameEncoding(rawValue: server.ftpEncoding) else { return nil }
        var connection = NASConnection(id: id, name: server.name, kind: kind, host: server.host, port: port,
            share: server.share, rootPath: server.rootPath, username: server.username, domain: server.domain, ftpEncoding: encoding)
        var path = recent.path
        if kind == .smb {
            let parts = path.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            connection.share = String(parts[0]); path = "/" + parts[1]
        }
        return key(connection: connection, entry: NASEntry(path: path, name: recent.name, isDirectory: false,
            size: recent.fileSize, modifiedAt: recent.modifiedAt.map(Date.init(timeIntervalSince1970:)), encodedPath: recent.encodedPath))
    }
}
