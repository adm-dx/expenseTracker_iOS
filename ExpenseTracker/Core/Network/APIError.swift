import Foundation

nonisolated enum APIError: Error, LocalizedError, Equatable {
    /// No connection, timeout and the like: the request may be retried later.
    case offline
    /// The session is over (refresh failed): the user has to sign in again.
    case unauthorized
    case server(status: Int, message: String)
    case decoding(String)
    case invalidResponse

    var isConnectivity: Bool { self == .offline }

    var status: Int? {
        if case .server(let status, _) = self { return status }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .offline: "Нет соединения с сервером"
        case .unauthorized: "Сессия истекла, войдите снова"
        case .server(_, let message): message
        case .decoding(let details): "Не удалось разобрать ответ сервера: \(details)"
        case .invalidResponse: "Некорректный ответ сервера"
        }
    }

    /// Nest's error body: `{ statusCode, message: string | string[], error }`.
    static func from(status: Int, data: Data) -> APIError {
        struct Body: Decodable {
            let message: Message?
            let error: String?
        }
        enum Message: Decodable {
            case one(String), many([String])
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let list = try? c.decode([String].self) { self = .many(list) } else { self = .one(try c.decode(String.self)) }
            }
            var text: String {
                switch self {
                case .one(let s): s
                case .many(let list): list.joined(separator: "\n")
                }
            }
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let message = body?.message?.text ?? body?.error ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return .server(status: status, message: message)
    }

    static func from(_ error: Error) -> APIError {
        if let api = error as? APIError { return api }
        if error is URLError { return .offline }
        if error is DecodingError { return .decoding(String(describing: error)) }
        return .server(status: 0, message: error.localizedDescription)
    }
}
