import Foundation

/// Stable public identity. Ephemeral signed media URLs never belong in history.
public struct YouTubeLink: Hashable, Sendable {
    public let videoID: String
    public var identity: String { "youtube:" + videoID }
    public var canonicalURL: URL { URL(string: "https://www.youtube.com/watch?v=" + videoID)! }
    public var thumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/" + videoID + "/hqdefault.jpg")! }

    public init?(videoID: String) {
        guard videoID.utf8.count == 11, videoID.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        self.videoID = videoID
    }

    public init?(text: String) {
        guard text.utf8.count <= 8_192 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Inspect whole tokens, never a substring inside another URL's authority,
        // path, query or fragment. Titles from a share sheet may surround one URL.
        let addresses = trimmed.split(whereSeparator: \.isWhitespace)
            .map { Self.unwrapped(String($0)) }.filter(Self.looksLikeAddress)
        guard addresses.count == 1, let url = Self.inputURL(addresses[0]) else { return nil }
        self.init(url: url)
    }

    private static let hosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"]

    private static func inputURL(_ value: String) -> URL? {
        if value.contains("://") { return URL(string: value) }
        let authority = value.prefix { !"/?#".contains($0) }
        guard hosts.contains(authority.lowercased()) else { return nil }
        return URL(string: "https://" + value)
    }

    private static func looksLikeAddress(_ value: String) -> Bool {
        value.contains("://") || value.hasPrefix("//") ||
            value.range(of: #"(?i)^(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[/:?#@]|$)"#, options: .regularExpression) != nil
    }

    private static func unwrapped(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              ["<": ">", "(": ")", "[": "]", "\"": "\"", "'": "'", "“": "”", "‘": "’"][String(first)] == String(last) else { return value }
        return String(value.dropFirst().dropLast())
    }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased(), !parts.percentEncodedPath.contains("%") else { return nil }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: true)
        let identifier: String?
        if ["youtu.be", "www.youtu.be"].contains(host), segments.count == 1 {
            identifier = String(segments[0])
        } else if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host) {
            if parts.path == "/watch" {
                let ids = (parts.queryItems ?? []).filter { $0.name == "v" }
                identifier = ids.count == 1 ? ids[0].value : nil
            } else if segments.count == 2, ["shorts", "embed", "live"].contains(String(segments[0])) {
                identifier = String(segments[1])
            } else { identifier = nil }
        } else { identifier = nil }
        guard let identifier else { return nil }
        self.init(videoID: identifier)
    }
}
