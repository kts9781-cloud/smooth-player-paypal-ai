import Foundation

@MainActor
enum NASCloudAdapter {
    static func connectionAliases(from previous: [String: NASCloudValue], to next: [String: NASCloudValue]) -> [UUID: UUID] {
        let discovered = Dictionary(uniqueKeysWithValues: NASDuplicateMerge.aliases(from: previous, to: next).compactMap { old, new -> (UUID, UUID)? in
            guard let a = UUID(uuidString: old), let b = UUID(uuidString: new) else { return nil }
            return (a, b)
        })
        var aliases = NASCredentialStore.connectionAliases.merging(discovered) { _, new in new }
        for (old, target) in aliases { aliases[old] = discovered[target] ?? target }
        return aliases.filter { old, target in
            next["server:" + old.uuidString.lowercased()] == nil && next["server:" + target.uuidString.lowercased()] != nil
        }
    }
    static func snapshot(connections: [NASConnection], recents: NASRecentStore, privacy: FolderPrivacyStore) throws -> [String: NASCloudValue] {
        guard recents.errorMessage == nil, privacy.errorMessage == nil else { throw NASError.credentialStorage }
        var values: [String: NASCloudValue] = [:]
        for c in connections {
            values["server:" + c.id.uuidString.lowercased()] = .server(NASCloudServer(name: c.name, protocol: c.kind.rawValue,
                host: c.host, port: Int(c.port), share: c.share, rootPath: c.rootPath, username: c.username,
                password: try NASCredentialStore.password(for: c.id), domain: c.domain, ftpEncoding: c.ftpEncoding.rawValue))
        }
        // Oldest first means duplicate legacy records resolve to the last watched item.
        for r in recents.videos.sorted(by: { $0.openedAt < $1.openedAt }) {
            guard let c = connections.first(where: { $0.id == r.connectionID }) else { continue }
            let share = c.kind == .smb ? (r.share ?? c.share) : ""
            let path = (share.isEmpty ? "" : "/" + share) + r.path
            let wire = c.kind == .ftp ? r.encodedPath : nil
            let id = c.id.uuidString.lowercased()
            values[NASCloudIdentity.recent(id, wire ?? path)] = .recent(NASCloudRecent(connectionID: id, path: path,
                encodedPath: wire, name: r.name, position: r.position, duration: r.duration, fileSize: r.fileSize,
                modifiedAt: r.modifiedAt?.timeIntervalSince1970, openedAt: r.openedAt.timeIntervalSince1970))
        }
        for rule in privacy.hiddenFolders where rule.bookmark == nil && (rule.location.scope.hasPrefix("ftp://") || rule.location.scope.hasPrefix("smb://")) {
            let l = rule.location
            values[NASCloudIdentity.hidden(l.scope, l.path)] = .hidden(NASCloudHidden(scope: l.scope, path: l.path, name: rule.name))
        }
        return values
    }
    static func decode(_ values: [String: NASCloudValue]) throws -> ([(NASConnection, String)], [NASRecentVideo], [HiddenFolderRule]) {
        var servers: [(NASConnection, String)] = []; var recents: [NASRecentVideo] = []; var hidden: [HiddenFolderRule] = []
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            guard let id = UUID(uuidString: String(key.split(separator: ":").last ?? "")) else { throw NASError.invalidConnection }
            switch value {
            case .server(let s):
                guard let kind = NASProtocol(rawValue: s.protocol), let port = UInt16(exactly: s.port), let encoding = FTPFilenameEncoding(rawValue: s.ftpEncoding) else { throw NASError.invalidConnection }
                let c = try NASConnection(id: id, name: s.name, kind: kind, host: s.host, port: port, share: s.share,
                    rootPath: s.rootPath, username: s.username, domain: s.domain, ftpEncoding: encoding).validated()
                servers.append((c, s.password))
            case .recent, .youtube: break
            case .hidden(let h):
                guard h.scope.hasPrefix("ftp://") || h.scope.hasPrefix("smb://") else { throw NASError.invalidPath }
                hidden.append(HiddenFolderRule(id: id, location: FolderPrivacyLocation(scope: h.scope, path: try NASPath.normalized(h.path)), name: h.name))
            }
        }
        for (key, value) in values {
            guard case .recent(let r) = value, let id = UUID(uuidString: String(key.dropFirst(7))),
                  let serverID = UUID(uuidString: r.connectionID), let c = servers.first(where: { $0.0.id == serverID })?.0 else { continue }
            var path = r.path; var share: String?
            if c.kind == .smb {
                let parts = path.split(separator: "/", maxSplits: 1)
                guard parts.count == 2 else { throw NASError.invalidPath }
                share = String(parts[0]); path = "/" + parts[1]
            }
            recents.append(NASRecentVideo(id: id, connectionID: serverID, path: path, encodedPath: r.encodedPath,
                name: r.name, position: r.position, duration: r.duration, fileSize: r.fileSize,
                modifiedAt: r.modifiedAt.map(Date.init(timeIntervalSince1970:)), openedAt: Date(timeIntervalSince1970: r.openedAt), share: share))
        }
        return (servers, recents, hidden)
    }
    #if !os(macOS)
    static func attach(account: AccountStore, servers: NASLibrary, recents: NASRecentStore, privacy: FolderPrivacyStore, library: MediaLibrary) -> NASAccountSync {
        NASAccountSync(account: account, includeYouTube: true, snapshot: {
            guard servers.errorMessage == nil else { throw NASError.credentialStorage }
            return try snapshot(connections: servers.connections, recents: recents, privacy: privacy)
                .merging(library.youtubeSnapshot()) { _, new in new }
        }, apply: { [weak account] values in
            library.bindYouTubeAccount(account?.session?.userId)
            let before = try snapshot(connections: servers.connections, recents: recents, privacy: privacy)
            NASVideoThumbnails.shared.preserveCachedPreviews(NASPreviewIdentity.migrations(from: before, to: values))
            let aliases = connectionAliases(from: before, to: values)
            let (connections, videos, rules) = try decode(values)
            try SubtitlePreferenceStore.shared.remapNASConnections(aliases, previous: before, current: values)
            try privacy.replaceNetworkRules(rules)
            try servers.replaceFromAccount(connections, aliases: aliases)
            try recents.replaceFromAccount(videos, aliases: aliases, validConnectionIDs: Set(connections.map { $0.0.id }))
            try library.replaceYouTubeFromAccount(values)
        })
    }
    #endif
}
