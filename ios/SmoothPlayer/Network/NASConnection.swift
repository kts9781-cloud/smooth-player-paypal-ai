import Foundation

enum NASProtocol: String, Codable, CaseIterable, Sendable {
    case smb, ftp
    var defaultPort: UInt16 { self == .smb ? 445 : 21 }
    var title: String { self == .smb ? "SMB" : "FTP" }
}

enum FTPFilenameEncoding: String, Codable, CaseIterable, Sendable {
    case automatic, utf8, cp949, eucKR
    var title: String {
        switch self {
        case .automatic: SPText("자동 (UTF-8 우선)")
        case .utf8: "UTF-8"
        case .cp949: SPText("한국어 (CP949)")
        case .eucKR: SPText("한국어 (EUC-KR)")
        }
    }
    var nativeValue: Int32 {
        switch self { case .automatic: 0; case .utf8: 1; case .cp949: 2; case .eucKR: 3 }
    }
}

/// Saved metadata never contains a password or an authenticated URL.
struct NASConnection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var kind: NASProtocol
    var host: String
    var port: UInt16
    var share: String
    var rootPath: String
    var username: String
    var domain: String
    var ftpEncoding: FTPFilenameEncoding

    init(id: UUID = UUID(), name: String, kind: NASProtocol, host: String, port: UInt16? = nil,
         share: String = "", rootPath: String = "/", username: String = "", domain: String = "", ftpEncoding: FTPFilenameEncoding = .automatic) {
        self.id = id; self.name = name; self.kind = kind; self.host = host
        self.port = port ?? kind.defaultPort; self.share = share; self.rootPath = rootPath
        self.username = username; self.domain = domain; self.ftpEncoding = ftpEncoding
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, share, rootPath, username, domain, ftpEncoding
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(NASProtocol.self, forKey: .kind)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(UInt16.self, forKey: .port)
        share = try values.decode(String.self, forKey: .share)
        rootPath = try values.decode(String.self, forKey: .rootPath)
        username = try values.decode(String.self, forKey: .username)
        domain = try values.decode(String.self, forKey: .domain)
        // Existing saved servers keep their UUID and Keychain password when upgraded.
        ftpEncoding = try values.decodeIfPresent(FTPFilenameEncoding.self, forKey: .ftpEncoding) ?? .automatic
    }

    func validated() throws -> Self {
        var result = self
        result.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.host.hasPrefix("[") && result.host.hasSuffix("]") {
            result.host = String(result.host.dropFirst().dropLast())
        }
        guard !result.host.isEmpty, result.host.utf8.count <= 253, port != 0,
              !result.host.contains(where: { "/@?#[]".contains($0) || $0.isWhitespace || $0.isNewline }),
              ![result.host, username, domain, share].contains(where: { $0.contains("\0") || $0.contains("\r") || $0.contains("\n") }),
              kind != .smb || (!share.contains("/") && !share.contains("\\")) else {
            throw NASError.invalidConnection
        }
        result.rootPath = try NASPath.normalized(rootPath)
        return result
    }
}

enum NASPath {
    static func normalized(_ path: String) throws -> String {
        guard path.utf8.count <= 8192, !path.contains("\0"), !path.contains("\r"),
              !path.contains("\n"), !path.contains("\\") else { throw NASError.invalidPath }
        let parts = path.split(separator: "/")
        guard !parts.contains("..") else { throw NASError.invalidPath }
        return "/" + parts.filter { $0 != "." }.joined(separator: "/")
    }
    static func child(_ name: String, of path: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw NASError.invalidPath
        }
        return try normalized(path + "/" + name)
    }
}

struct NASEntry: Identifiable, Hashable, Sendable {
    var id: String { encodedPath ?? path }
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
    /// Opaque FTP wire bytes, percent escaped by the native listing parser. Never derive
    /// a request path by re-encoding the displayed Unicode filename.
    var encodedPath: String? = nil
}

enum NASError: Error, LocalizedError, Equatable {
    case invalidConnection, invalidPath, connectionFailed, authenticationFailed, timedOut, closed, limitExceeded, credentialStorage, filenameEncoding
    var errorDescription: String? {
        switch self {
        case .invalidConnection: return SPText("서버 주소·포트·공유 폴더 정보를 확인해 주세요.")
        case .invalidPath: return SPText("열 수 없는 파일 경로입니다.")
        case .connectionFailed: return SPText("서버에 연결하거나 파일을 읽을 수 없습니다. 네트워크와 로그인 정보를 확인해 주세요.")
        case .authenticationFailed: return SPText("서버 로그인 정보를 확인해 주세요.")
        case .timedOut: return SPText("서버 응답 시간이 초과되었습니다. 다시 시도해 주세요.")
        case .closed: return SPText("파일 연결이 종료되었습니다. 다시 열어 주세요.")
        case .limitExceeded: return SPText("한 번에 처리할 수 있는 파일 목록이나 읽기 크기를 넘었습니다.")
        case .filenameEncoding: return SPText("파일 이름의 인코딩을 읽지 못했습니다. 서버 편집에서 파일 이름 인코딩을 UTF-8, 한국어(CP949), 한국어(EUC-KR) 중 서버 설정에 맞게 선택해 주세요.")
        case .credentialStorage: return SPText("서버 비밀번호를 안전하게 저장하거나 읽지 못했습니다.")
        }
    }
}
