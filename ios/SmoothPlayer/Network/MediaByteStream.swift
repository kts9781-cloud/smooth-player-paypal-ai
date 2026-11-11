import Foundation

/// Random-access bytes for the existing custom AVIO decoder. Implementations
/// own their transport and never expose source URLs to the native demuxer.
protocol MediaByteStream: AnyObject, Sendable {
    var size: Int64 { get }
    func read(offset: Int64, count: Int) async throws -> Data
    func close() async
}

extension NASFileStream: MediaByteStream {}
