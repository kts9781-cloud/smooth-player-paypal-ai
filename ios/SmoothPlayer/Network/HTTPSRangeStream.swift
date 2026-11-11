import Foundation

enum HTTPSRangeError: LocalizedError {
    case invalidURL, unsupportedRange, invalidResponse, changedResource, expiredOrDenied, connectionFailed, closed
    var errorDescription: String? {
        switch self {
        case .invalidURL: SPText("HTTPS 동영상 주소를 확인해 주세요.")
        case .unsupportedRange: SPText("이 서버는 동영상 구간 읽기를 지원하지 않습니다.")
        case .invalidResponse: SPText("서버에서 올바른 동영상 데이터를 받지 못했습니다.")
        case .changedResource: SPText("동영상이 변경되었습니다. 주소를 다시 열어 주세요.")
        case .expiredOrDenied: SPText("동영상 주소가 만료되었거나 접근할 수 없습니다. 다시 열어 주세요.")
        case .connectionFailed: SPText("동영상 서버에 연결하지 못했습니다. 다시 시도해 주세요.")
        case .closed: SPText("동영상 연결이 종료되었습니다.")
        }
    }
}

enum HTTPSRangePolicy: Sendable {
    case httpsOnly
    /// Explicit injection for synthetic loopback tests; never enabled by user URLs.
    case loopbackForTesting
    fileprivate func allows(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return self == .loopbackForTesting && url.scheme?.lowercased() == "http" &&
            ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host)
    }
}

/// A bounded progressive-file transport, not an HLS/DASH manifest loader.
/// The decoder's byte-limited window cache is reused; no whole-file download,
/// shared cookies, URL credentials, persistent URL cache or URL logging occurs.
final class HTTPSRangeStream: MediaByteStream, @unchecked Sendable {
    let size: Int64
    private let url: URL
    private let validator: HTTPSRangeTransport.Validator?
    private let transport: HTTPSRangeTransport

    private init(url: URL, size: Int64, validator: HTTPSRangeTransport.Validator?, transport: HTTPSRangeTransport) {
        self.url = url; self.size = size; self.validator = validator; self.transport = transport
    }

    static func open(url: URL, policy: HTTPSRangePolicy = .httpsOnly) async throws -> HTTPSRangeStream {
        guard policy.allows(url) else { throw HTTPSRangeError.invalidURL }
        let transport = HTTPSRangeTransport(policy: policy)
        do {
            let response = try await transport.read(url: url, offset: 0, count: 1, size: nil, validator: nil)
            try Task.checkCancellation()
            return HTTPSRangeStream(url: response.url, size: response.size, validator: response.validator, transport: transport)
        } catch { transport.close(); throw error }
    }

    func read(offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, offset <= size, count >= 0, count <= 8 * 1_048_576 else { throw HTTPSRangeError.invalidResponse }
        guard count > 0, offset < size else { return Data() }
        let response = try await transport.read(url: url, offset: offset, count: Int(min(Int64(count), size - offset)),
            size: size, validator: validator)
        try Task.checkCancellation()
        return response.data
    }
    func close() async { transport.close() }
    deinit { transport.close() }
}

private final class HTTPSRangeTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Validator: Equatable, Sendable { let header: String; let value: String }
    struct Response: Sendable { let url: URL; let size: Int64; let validator: Validator?; let data: Data }
    private final class Pending {
        let offset: Int64, count: Int, size: Int64?, validator: Validator?
        let continuation: CheckedContinuation<Response, Error>
        var data = Data(), responseURL: URL?, responseSize: Int64?, responseValidator: Validator?
        var failure: Error?, redirects = 0
        init(offset: Int64, count: Int, size: Int64?, validator: Validator?, continuation: CheckedContinuation<Response, Error>) {
            self.offset = offset; self.count = count; self.size = size; self.validator = validator; self.continuation = continuation
        }
    }
    private final class TaskHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func install(_ task: URLSessionDataTask) {
            lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
            if cancel { task.cancel() }
        }
        func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    }
    private let policy: HTTPSRangePolicy
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var closed = false
    private var session: URLSession!

    init(policy: HTTPSRangePolicy) {
        self.policy = policy
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.name = "com.nodelabs.smoothplayer.https-range"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func read(url: URL, offset: Int64, count: Int, size: Int64?, validator: Validator?) async throws -> Response {
        try Task.checkCancellation()
        let handle = TaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !closed else { lock.unlock(); continuation.resume(throwing: HTTPSRangeError.closed); return }
                let task = session.dataTask(with: request(url: url, offset: offset, count: count, validator: validator))
                pending[task.taskIdentifier] = Pending(offset: offset, count: count, size: size, validator: validator, continuation: continuation)
                lock.unlock()
                handle.install(task); task.resume()
            }
        } onCancel: { handle.cancel() }
    }

    private func request(url: URL, offset: Int64, count: Int, validator: Validator?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpShouldHandleCookies = false
        if let validator { request.setValue(validator.value, forHTTPHeaderField: "If-Range") }
        return request
    }

    func close() {
        lock.lock(); let shouldClose = !closed; closed = true; lock.unlock()
        if shouldClose { session.invalidateAndCancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        guard let item = pending[task.taskIdentifier], let url = newRequest.url,
              policy.allows(url), item.redirects < 5, !closed else {
            pending[task.taskIdentifier]?.failure = HTTPSRangeError.invalidURL
            lock.unlock(); completionHandler(nil); return
        }
        item.redirects += 1
        let redirected = request(url: url, offset: item.offset, count: item.count, validator: item.validator)
        lock.unlock(); completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard let item = pending[dataTask.taskIdentifier] else { lock.unlock(); completionHandler(.cancel); return }
        do {
            guard item.failure == nil, !closed else { throw item.failure ?? HTTPSRangeError.closed }
            guard let http = response as? HTTPURLResponse, let url = http.url, policy.allows(url) else { throw HTTPSRangeError.invalidResponse }
            if http.statusCode == 401 || http.statusCode == 403 { throw HTTPSRangeError.expiredOrDenied }
            guard http.statusCode == 206 else { throw HTTPSRangeError.unsupportedRange }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard encoding == nil || encoding == "identity" else { throw HTTPSRangeError.invalidResponse }
            guard let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")),
                  range.start == item.offset, range.end - range.start + 1 == Int64(item.count),
                  item.size == nil || item.size == range.size else { throw HTTPSRangeError.invalidResponse }
            if let length = http.value(forHTTPHeaderField: "Content-Length") {
                guard Int64(length) == Int64(item.count) else { throw HTTPSRangeError.invalidResponse }
            }
            let validator = Self.validator(http)
            if let expected = item.validator, validator != expected { throw HTTPSRangeError.changedResource }
            item.responseURL = url; item.responseSize = range.size; item.responseValidator = validator
            lock.unlock(); completionHandler(.allow)
        } catch { item.failure = error; lock.unlock(); completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let item = pending[dataTask.taskIdentifier] else { lock.unlock(); dataTask.cancel(); return }
        guard item.failure == nil, item.responseSize != nil, data.count <= item.count - item.data.count, !closed else {
            item.failure = item.failure ?? HTTPSRangeError.invalidResponse
            lock.unlock(); dataTask.cancel(); return
        }
        item.data.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let item = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let item else { return }
        if let failure = item.failure { item.continuation.resume(throwing: failure) }
        else if let error {
            item.continuation.resume(throwing: (error as NSError).code == NSURLErrorCancelled ? CancellationError() : HTTPSRangeError.connectionFailed)
        } else if let url = item.responseURL, let size = item.responseSize, item.data.count == item.count {
            item.continuation.resume(returning: Response(url: url, size: size, validator: item.responseValidator, data: item.data))
        } else { item.continuation.resume(throwing: HTTPSRangeError.invalidResponse) }
    }

    private static func validator(_ response: HTTPURLResponse) -> Validator? {
        if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/"), !etag.isEmpty {
            return Validator(header: "ETag", value: etag)
        }
        if let modified = response.value(forHTTPHeaderField: "Last-Modified"), !modified.isEmpty {
            return Validator(header: "Last-Modified", value: modified)
        }
        return nil
    }
    private static func contentRange(_ value: String?) -> (start: Int64, end: Int64, size: Int64)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let size = Int64(parts[1]), size > 0 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < size else { return nil }
        return (start, end, size)
    }
}
