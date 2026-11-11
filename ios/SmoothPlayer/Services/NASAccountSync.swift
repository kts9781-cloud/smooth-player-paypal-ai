import Foundation
import Observation
import CryptoKit
import Security

/// NAS and opted-in public YouTube history. Local files never enter this coordinator.
@MainActor @Observable
final class NASAccountSync {
    struct Profile: Codable {
        var base: [String: NASCloudRecord] = [:]
        var local: [String: NASCloudValue] = [:]
        var conflicts: [String: NASCloudChange] = [:]
    }
    private struct Vault: Codable { var owner: String?; var profiles: [String: Profile] = [:]; var needsApply = false; var hasBoundAccount = false }
    private var vault = Vault()
    private var loaded = false
    private var switching = false
    private var previewRecoveryOwners: Set<String> = []
    private var epoch = 0
    private let file: URL
    private let keyName: String
    private var lastSaved: Data?
    private var key: SymmetricKey?
    private let snapshot: () throws -> [String: NASCloudValue]
    private let apply: ([String: NASCloudValue]) throws -> Void
    private let includeYouTube: Bool
    var accessReady: Bool { loaded && !vault.needsApply && vault.owner == account?.session?.userId }
    private(set) var busy = false
    private(set) var message = SPText("로그인하면 NAS 설정·비밀번호·최근 목록을 동기화합니다.")
    private(set) var conflictCount = 0
    private weak var account: AccountStore?

    init(account: AccountStore, namespace: String = "default", storageRoot: URL = .applicationSupportDirectory, includeYouTube: Bool = false, snapshot: @escaping () throws -> [String: NASCloudValue],
         apply: @escaping ([String: NASCloudValue]) throws -> Void) {
        self.account = account; self.snapshot = snapshot; self.apply = apply
        self.includeYouTube = includeYouTube
        keyName = NASCloudIdentity.uuid((account.configuration?.origin.absoluteString ?? "unconfigured") + namespace)
        file = storageRoot.appending(path: "nas-account-sync/" + keyName + ".bin")
    }
    func run() async {
        while !Task.isCancelled {
            await synchronize()
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
        }
    }
    func accountChanged() {
        epoch += 1
        do { try activate() } catch { message = SPText("NAS 계정 저장소를 읽거나 전환하지 못했습니다. 동기화를 중단했습니다.") }
    }
    private func activate() throws {
        guard !switching else { return }; switching = true; defer { switching = false }
        if !loaded { try load(); loaded = true }
        if vault.needsApply {
            try apply(vault.owner.flatMap { vault.profiles[$0]?.local } ?? [:])
            vault.needsApply = false; try save()
        }
        let next = account?.session?.userId
        guard vault.owner != next else { return }
        epoch += 1
        if let owner = vault.owner {
            vault.profiles[owner, default: Profile()].local = try snapshot()
        }
        let first = !vault.hasBoundAccount && vault.owner == nil
        if let next {
            if first { vault.profiles[next] = Profile(local: try snapshot()) }
            else if includeYouTube && vault.owner == nil {
                // Previously device-only links (or new guest watches) join the account
                // being logged in. Never transfer links directly between two accounts.
                for (id, value) in try snapshot() {
                    guard case .youtube(let watch) = value else { continue }
                    if case .youtube(let saved) = vault.profiles[next]?.local[id], saved.openedAt > watch.openedAt { continue }
                    vault.profiles[next, default: Profile()].local[id] = value
                }
            }
            vault.hasBoundAccount = true
        }
        vault.owner = next
        vault.needsApply = true; try save()
        try apply(next.flatMap { vault.profiles[$0]?.local } ?? [:])
        vault.needsApply = false
        conflictCount = next.flatMap { vault.profiles[$0]?.conflicts.count } ?? 0
        try save()
    }
    func synchronize() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try activate()
            guard let account, let owner = vault.owner, account.session?.userId == owner else { return }
            let generation = epoch
            let observed = try snapshot()
            recoverPreviews(owner: owner, current: observed)
            var profile = vault.profiles[owner] ?? Profile()
            profile.local = observed; vault.profiles[owner] = profile; try save()
            let current = NASDuplicateMerge.merge(observed)
            if current != observed {
                try preserveBeforeMerge()
                profile.local = current; vault.profiles[owner] = profile
                vault.needsApply = true; try save()
                try apply(current)
                vault.needsApply = false
            }
            profile.local = current; vault.profiles[owner] = profile; try save()
            let keys = Set(current.keys).union(profile.base.keys)
            let changes = keys.sorted().compactMap { id -> NASCloudChange? in
                let previous = profile.base[id]
                guard previous?.value != current[id] else { return nil }
                return NASCloudChange(id: id, baseVersion: previous?.version ?? 0, value: current[id])
            }
            let reply = try await account.syncNAS(NASCloudRequest(changes: changes, includeYouTube: includeYouTube ? true : nil))
            guard generation == epoch, account.session?.userId == owner, reply.userId == owner, reply.schema == 1 else { return }
            let now = try snapshot()
            var merged = Dictionary(uniqueKeysWithValues: reply.records.compactMap { r in r.value.map { (r.id, $0) } })
            // Edits made while HTTP was in flight remain dirty for the next round.
            for id in Set(now.keys).union(current.keys) where now[id] != current[id] { merged[id] = now[id] }
            for id in reply.conflicts { profile.conflicts[id] = NASCloudChange(id: id, baseVersion: profile.base[id]?.version ?? 0, value: current[id]) }
            profile.base = Dictionary(uniqueKeysWithValues: reply.records.map { ($0.id, $0) })
            let consolidated = NASDuplicateMerge.merge(merged)
            if consolidated != merged {
                profile.local = merged; vault.profiles[owner] = profile; try save()
                try preserveBeforeMerge()
                merged = consolidated
            }
            profile.local = merged
            vault.profiles[owner] = profile; vault.needsApply = true; try save()
            if merged != now { try apply(merged) }
            vault.needsApply = false; try save()
            conflictCount = profile.conflicts.count
            message = conflictCount > 0 ? SPText("다른 기기의 변경을 적용했습니다. 충돌한 이 기기 변경은 따로 보관했습니다.") : SPText("NAS 설정·비밀번호·최근 목록 동기화 완료")
        } catch {
            message = SPText("NAS 동기화를 완료하지 못했습니다. 연결이 복구되면 다시 시도합니다.")
        }
    }
    func restoreConflicts() {
        guard let owner = vault.owner, var profile = vault.profiles[owner] else { return }
        do {
            var current = try snapshot()
            for (id, change) in profile.conflicts { current[id] = change.value }
            current = current.filter { _, value in
                if case .recent(let r) = value { return current["server:" + r.connectionID] != nil }; return true
            }
            profile.local = current
            vault.profiles[owner] = profile; vault.needsApply = true; try save()
            try apply(current); vault.needsApply = false; profile.conflicts = [:]
            vault.profiles[owner] = profile; conflictCount = 0; try save()
        } catch { message = SPText("보관한 변경을 복원하지 못했습니다.") }
    }
    func eraseCurrentAccount() throws {
        guard let owner = vault.owner else { return }
        epoch += 1
        vault.profiles.removeValue(forKey: owner); vault.owner = nil; vault.needsApply = true
        try save(); try apply([:]); vault.needsApply = false; try save()
    }
    private func load() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.nodelabs.smoothplayer.nas-sync", kSecAttrAccount as String: keyName]
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let bytes = result as? Data { key = SymmetricKey(data: bytes) }
        else if status == errSecItemNotFound && !FileManager.default.fileExists(atPath: file.path) {
            let created = SymmetricKey(size: .bits256); let bytes = created.withUnsafeBytes { Data($0) }
            var item = query; item[kSecValueData as String] = bytes; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw NASError.credentialStorage }
            key = created
        } else { throw NASError.credentialStorage }
        if FileManager.default.fileExists(atPath: file.path), let key {
            let data = try Data(contentsOf: file)
            guard data.count <= 8_388_608 else { throw NASError.limitExceeded }
            vault = try JSONDecoder().decode(Vault.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key))
        }
    }
    /// Preserve the existing encrypted account document before the first repair.
    /// No credential or server address is written in plaintext by this backup.
    private func preserveBeforeMerge() throws {
        for suffix in ["before-duplicate-merge", "before-recent-path-merge"] {
            let backup = file.appendingPathExtension(suffix)
            if FileManager.default.fileExists(atPath: backup.path) { continue }
            try FileManager.default.copyItem(at: file, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
    }
    private func recoverPreviews(owner: String, current: [String: NASCloudValue]) {
        guard !previewRecoveryOwners.contains(owner), let key else { return }
        previewRecoveryOwners.insert(owner)
        let backup = file.appendingPathExtension("before-duplicate-merge")
        guard let data = try? Data(contentsOf: backup), data.count <= 8_388_608,
              let box = try? AES.GCM.SealedBox(combined: data), let plain = try? AES.GCM.open(box, using: key),
              let previous = try? JSONDecoder().decode(Vault.self, from: plain), let values = previous.profiles[owner]?.local else { return }
        NASVideoThumbnails.shared.preserveCachedPreviews(NASPreviewIdentity.migrations(from: values, to: current))
    }
    private func save() throws {
        guard let key else { throw NASError.credentialStorage }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(vault)
        guard encoded != lastSaved else { return }
        guard encoded.count <= 8_000_000 else { throw NASError.limitExceeded }
        let data = try AES.GCM.seal(encoded, using: key).combined!
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        lastSaved = encoded
    }
}
