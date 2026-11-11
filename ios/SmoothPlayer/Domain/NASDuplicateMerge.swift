import Foundation

/// Only byte-for-byte equivalent server settings (including name and credential)
/// are duplicates. Host aliases, other users and different passwords stay separate.
enum NASDuplicateMerge {
    static func aliases(from previous: [String: NASCloudValue], to next: [String: NASCloudValue]) -> [String: String] {
        var result: [String: String] = [:]
        let targets = next.keys.sorted()
        for (key, value) in previous where key.hasPrefix("server:") && next[key] == nil {
            guard case .server = value,
                  let target = targets.first(where: { $0.hasPrefix("server:") && next[$0] == value }) else { continue }
            result[String(key.dropFirst(7))] = String(target.dropFirst(7))
        }
        return result
    }

    static func merge(_ input: [String: NASCloudValue]) -> [String: NASCloudValue] {
        var output = input
        var retained: [(String, NASCloudServer)] = []
        var redirects: [String: String] = [:]
        for key in input.keys.sorted() {
            guard key.hasPrefix("server:"), case .server(let server) = input[key] else { continue }
            if let existing = retained.first(where: { $0.1 == server }) {
                redirects[String(key.dropFirst(7))] = String(existing.0.dropFirst(7))
                output.removeValue(forKey: key)
            } else { retained.append((key, server)) }
        }
        // Resolve duplicate movie positions using last-watched time, never the
        // largest seek position (rewatching and completed=0 must remain possible).
        let history = input.compactMap { key, value -> (String, NASCloudRecent)? in
            guard case .recent(let recent) = value else { return nil }
            return (key, recent)
        }.sorted { $0.1.openedAt == $1.1.openedAt ? $0.0 < $1.0 : $0.1.openedAt < $1.1.openedAt }
        // Legacy display paths and opaque listing paths can identify the same file
        // even after server registrations have already been consolidated.
        var paths: [String: Set<String>] = [:]
        for (_, recent) in history {
            let connection = redirects[recent.connectionID] ?? recent.connectionID
            if let wire = recent.encodedPath { paths[connection + "\n" + recent.path, default: []].insert(wire) }
        }
        for (key, _) in history {
            output.removeValue(forKey: key)
        }
        for (_, var recent) in history {
            recent.connectionID = redirects[recent.connectionID] ?? recent.connectionID
            // Multiple opaque paths with the same displayed name are ambiguous;
            // do not guess or merge those distinct filenames.
            if recent.encodedPath == nil, let wires = paths[recent.connectionID + "\n" + recent.path], wires.count == 1 {
                recent.encodedPath = wires.first
            }
            output[NASCloudIdentity.recent(recent.connectionID, recent.encodedPath ?? recent.path)] = .recent(recent)
        }
        return output
    }

    static func replacement(for old: NASCloudRecent, connectionID: String, in next: [String: NASCloudValue]) -> NASCloudRecent? {
        if case .recent(let current) = next[NASCloudIdentity.recent(connectionID, old.encodedPath ?? old.path)] { return current }
        guard old.encodedPath == nil else { return nil }
        let candidates = next.values.compactMap { value -> NASCloudRecent? in
            guard case .recent(let r) = value, r.connectionID == connectionID, r.path == old.path else { return nil }
            return r
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
