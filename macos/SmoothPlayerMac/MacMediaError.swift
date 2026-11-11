import Foundation

/// Platform wording for the shared AVAsset frame source; the iOS library owns
/// its corresponding file-picker error in MediaLibrary.swift.
enum MediaError: LocalizedError {
    case localFilesOnly, expiredBookmark, unsupportedFormat
    var errorDescription: String? {
        switch self {
        case .localFilesOnly: SPText("Finder에서 동영상 파일을 선택해 주세요.")
        case .expiredBookmark: SPText("파일 접근 권한이 만료되었습니다. 파일 열기로 다시 선택해 주세요.")
        case .unsupportedFormat: SPText("동영상을 읽지 못했습니다. 파일이 손상되었거나 암호화되어 있는지 확인해 주세요.")
        }
    }
}
