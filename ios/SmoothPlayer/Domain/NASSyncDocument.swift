import Foundation
import CryptoKit

struct NASCloudServer: Codable, Equatable {
    var kind = "server"
    var name: String
    var `protocol`: String
    var host: String
    var port: Int
    var share: String
    var rootPath: String
    var username: String
    var password: String
    var domain: String
    var ftpEncoding: String
}
struct NASCloudRecent: Codable, Equatable {
    var kind = "recent"
    var connectionID: String
    var path: String
    var encodedPath: String?
    var name: String
    var position: Double
    var duration: Double
    var fileSize: Int64
    var modifiedAt: Double?
    var openedAt: Double
}
struct NASCloudHidden: Codable, Equatable {
    var kind = "hidden"
    var scope: String
    var path: String
    var name: String
}
struct YouTubeCloudRecent: Codable, Equatable {
    var kind = "youtube"
    var videoID: String
    var title: String
    var position: Double
    var duration: Double
    var openedAt: Double
}
enum NASCloudValue: Codable, Equatable {
    case server(NASCloudServer), recent(NASCloudRecent), hidden(NASCloudHidden), youtube(YouTubeCloudRecent)
    enum Keys: String, CodingKey { case kind }
    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .kind)
        switch kind {
        case "server": self = .server(try NASCloudServer(from: decoder))
        case "recent": self = .recent(try NASCloudRecent(from: decoder))
        case "hidden": self = .hidden(try NASCloudHidden(from: decoder))
        case "youtube": self = .youtube(try YouTubeCloudRecent(from: decoder))
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported NAS record"))
        }
    }
    func encode(to encoder: Encoder) throws {
        switch self {
        case .server(let value): try value.encode(to: encoder)
        case .recent(let value): try value.encode(to: encoder)
        case .hidden(let value): try value.encode(to: encoder)
        case .youtube(let value): try value.encode(to: encoder)
        }
    }
}
struct NASCloudRecord: Codable, Equatable {
    let id: String
    let version: Int
    let value: NASCloudValue?
}
struct NASCloudChange: Codable {
    let id: String
    let baseVersion: Int
    let value: NASCloudValue?
    enum Keys: String, CodingKey { case id, baseVersion, value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(baseVersion, forKey: .baseVersion)
        try c.encode(value, forKey: .value)
    }
}
struct NASCloudRequest: Encodable {
    let schema = 1
    let changes: [NASCloudChange]
    // Omitted by Mac/legacy clients that do not offer YouTube playback.
    var includeYouTube: Bool? = nil
}
struct NASCloudReply: Decodable { let schema: Int; let userId: String; let records: [NASCloudRecord]; let conflicts: [String] }

enum NASCloudIdentity {
    static func uuid(_ text: String) -> String {
        let hex = SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let p = Array(hex)
        return [String(p[0..<8]), String(p[8..<12]), String(p[12..<16]), String(p[16..<20]), String(p[20..<32])].joined(separator: "-")
    }
    static func recent(_ connection: String, _ path: String) -> String { "recent:" + uuid(connection.lowercased() + "\n" + path) }
    static func hidden(_ scope: String, _ path: String) -> String { "hidden:" + uuid(scope + "\n" + path) }
    static func youtube(_ videoID: String) -> String { "youtube:" + uuid(videoID) }
}
