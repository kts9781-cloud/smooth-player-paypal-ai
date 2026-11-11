import Foundation

struct EmbeddedSubtitleTrack: Identifiable, Equatable, Sendable {
    let id: Int32
    let codecID: Int32
    let language: String
    let title: String
    let codecName: String
    let isDefault: Bool
    let isForced: Bool
    let supported: Bool
    let extraData: Data
    var label: String {
        [title.isEmpty ? SPText("자막 \(id + 1)") : title, language, codecName.uppercased()]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
struct NativeSubtitlePacket: Sendable {
    let trackID: Int32
    let data: Data
    let time: Double
    let duration: Double
}
