import Foundation
@testable import ExpenseTracker

/// Answers every request of a test URLSession with `handler`.
nonisolated final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var body: String }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest, Data?) -> Reply)?
    nonisolated(unsafe) private static var log: [(method: String, path: String, auth: String?, body: Data?)] = []

    static func setHandler(_ handler: @escaping @Sendable (URLRequest, Data?) -> Reply) {
        lock.withLock {
            self.handler = handler
            log = []
        }
    }

    static var requests: [(method: String, path: String, auth: String?, body: Data?)] { lock.withLock { log } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let reply: Reply = Self.lock.withLock {
            Self.log.append((request.httpMethod ?? "GET", request.url?.path ?? "", request.value(forHTTPHeaderField: "Authorization"), body))
            return Self.handler?(request, body) ?? Reply(status: 500, body: "{}")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

nonisolated enum Fixture {
    static func transaction(id: String, amount: String = "12.50", currency: String = "EUR", type: String = "EXPENSE",
                            description: String? = "Coffee", date: String = "2026-11-08T00:00:00.000Z",
                            categoryId: String = "cat-1", tagIds: [String] = [], converted: String? = nil) -> String {
        let desc = description.map { "\"\($0)\"" } ?? "null"
        let tags = tagIds.map { "\"\($0)\"" }.joined(separator: ",")
        let conv = converted.map { ",\"convertedAmount\":\"\($0)\"" } ?? ""
        return """
        {"id":"\(id)","amount":"\(amount)","currency":"\(currency)","type":"\(type)","description":\(desc),\
        "date":"\(date)","categoryId":"\(categoryId)","tagIds":[\(tags)],"createdAt":"2026-11-08T10:15:30.123Z"\(conv)}
        """
    }

    static func page(_ items: [String]) -> String {
        """
        {"items":[\(items.joined(separator: ","))],"total":\(items.count),"page":1,"pageSize":50,"currency":"EUR","ratesDate":null}
        """
    }

    static func json(_ data: Data?) -> [String: Any] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
