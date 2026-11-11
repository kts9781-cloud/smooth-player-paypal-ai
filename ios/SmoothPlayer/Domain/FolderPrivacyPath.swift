import Foundation

struct FolderPrivacyLocation: Codable, Equatable, Sendable {
    let scope: String
    let path: String
    func contains(_ other: Self) -> Bool {
        scope == other.scope && (path == other.path || path == "/" || other.path.hasPrefix(path + "/"))
    }
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
}
