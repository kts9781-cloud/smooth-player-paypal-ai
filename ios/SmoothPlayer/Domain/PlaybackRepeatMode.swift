import Foundation

enum PlaybackRepeatMode: String, Codable, CaseIterable, Sendable {
    case off, folder, one
    var next: Self { switch self { case .off: .folder; case .folder: .one; case .one: .off } }
    var symbolName: String { self == .one ? "repeat.1" : "repeat" }
    var titleKey: AppLocalizedMessage { switch self { case .off: "반복 끔"; case .folder: "폴더 전체 반복"; case .one: "현재 영상 반복" } }
    func nextIndex(current: Int, count: Int) -> Int? {
        guard (0..<count).contains(current), self != .off else { return nil }
        return self == .one ? current : (current + 1) % count
    }
}
