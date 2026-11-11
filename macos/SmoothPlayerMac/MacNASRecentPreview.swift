import SwiftUI

/// Only visible, unlocked history rows request a bounded preview; playback cancels decoding work.
struct MacNASRecentPreview: View {
    let connection: NASConnection
    let record: NASRecentVideo
    let enabled: Bool
    @State private var preview = VideoPreviewState()
    private var entry: NASEntry {
        NASEntry(path: record.path, name: record.name, isDirectory: false, size: record.fileSize,
                 modifiedAt: record.modifiedAt, encodedPath: record.encodedPath)
    }
    private var key: String { NASVideoThumbnails.key(connection: connection, entry: entry) }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                MacDeck.background
                if preview.key == key, let image = preview.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if preview.key == key && preview.loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "play.rectangle").foregroundStyle(MacDeck.muted) }
            }.clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SPText("영상 미리보기"))
        .accessibilityValue(preview.key == key && preview.image != nil ? SPText("완료") : "")
        .accessibilityIdentifier("nasRecentThumbnail")
        .task(id: "\(key)-\(enabled)") {
            await preview.load(key: key, enabled: enabled,
                               cached: { NASVideoThumbnails.shared.cached(key: key) }) {
                await NASVideoThumbnails.shared.load(connection: connection, entry: entry)
            }
        }
    }
}
