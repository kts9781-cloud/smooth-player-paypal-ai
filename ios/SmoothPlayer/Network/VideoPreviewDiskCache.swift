import CoreGraphics
import Foundation
import ImageIO

/// JPEG-only, bounded, backup-excluded cache. All calls are serialized independently of the UI.
final class VideoPreviewDiskCache: @unchecked Sendable {
    static let maximumBytes = 128 * 1024 * 1024
    private let directory: URL
    private let limit: Int
    private let lock = NSLock()
    init(directory: URL, limit: Int = maximumBytes) { self.directory = directory; self.limit = limit }
    private func file(_ key: String) -> URL? {
        guard key.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return directory.appending(path: key + ".jpg")
    }
    func load(key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let url = file(key), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 256 * 1024, let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 240, height <= 144,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }
    func save(_ image: CGImage, key: String) {
        lock.lock(); defer { lock.unlock() }
        guard let url = file(key), image.width <= 240, image.height <= 144 else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= min(limit, 256 * 1024) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory, values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            #if os(iOS)
            try (data as Data).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try (data as Data).write(to: url, options: .atomic)
            #endif
            var saved = url
            try saved.setResourceValues(values)
            trim()
        } catch { /* A cache failure must never block playback or a visible preview. */ }
    }
    private func trim() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let value = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, value.fileSize ?? 0, value.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries where bytes > limit {
            if (try? FileManager.default.removeItem(at: url)) != nil { bytes -= size }
        }
    }
    /// Keep the original file as a fallback; never relabel pixels for a changed revision.
    func copy(from source: String, to target: String) {
        lock.lock(); defer { lock.unlock() }
        guard source != target, let old = file(source), let new = file(target),
              !FileManager.default.fileExists(atPath: new.path),
              let size = try? old.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 256 * 1024 else { return }
        do { try FileManager.default.copyItem(at: old, to: new); trim() } catch { }
    }
    func erase() throws {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

