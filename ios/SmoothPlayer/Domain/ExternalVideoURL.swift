import Foundation

/// Custom links intentionally do not claim ownership of youtube.com universal links.
/// A normal YouTube URL can always be pasted; other apps can also use
/// smoothplayer://open?url=<percent-encoded HTTPS or YouTube URL>.
enum ExternalVideoURL {
    static func unwrap(_ url: URL) -> URL? {
        guard url.absoluteString.utf8.count <= 16_384 else { return nil }
        guard url.scheme?.lowercased() == "smoothplayer" else { return url }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "open", components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let queries = components.queryItems, queries.count == 1,
              queries[0].name == "url", let value = queries[0].value,
              value.utf8.count <= 8_192, let nested = URL(string: value),
              ["https", "http"].contains(nested.scheme?.lowercased() ?? "") else { return nil }
        return nested
    }
}
