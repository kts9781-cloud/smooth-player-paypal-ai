import Foundation

/// Folder order is supplied by the browser; unrelated recent items never become siblings.
struct VideoPlaylist<Item> {
    private(set) var items: [Item] = []
    private(set) var index: Int = 0
    var current: Item? { items.indices.contains(index) ? items[index] : nil }
    var hasPrevious: Bool { !items.isEmpty && index > 0 }
    var hasNext: Bool { index + 1 < items.count }

    mutating func replace(_ items: [Item], selected: Int) {
        guard items.indices.contains(selected) else { self.items = []; index = 0; return }
        self.items = items; index = selected
    }
    @discardableResult mutating func move(_ offset: Int) -> Item? {
        guard (offset == -1 || offset == 1), items.indices.contains(index + offset) else { return nil }
        index += offset
        return current
    }
    @discardableResult mutating func advanceAfterEnd(_ mode: PlaybackRepeatMode) -> Item? {
        guard let next = mode.nextIndex(current: index, count: items.count) else { return nil }
        index = next
        return current
    }
}
