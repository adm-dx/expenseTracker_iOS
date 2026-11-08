import Foundation

/// Sends requests to the API and keeps the session alive.
///
/// The server rotates refresh tokens and treats reuse of an old one as theft (it then ends every
/// session), so all requests that hit a 401 share one refresh call, and the new pair is stored
/// before any request is retried.
final class APIClient {
    let baseURL: URL
    private let session: URLSession
    private let tokens: TokenStore
    private var refreshTask: Task<AuthTokens, Error>?

    /// Called when the refresh token is rejected: the user must sign in again.
    var onSessionExpired: (() -> Void)?

    init(baseURL: URL, tokens: TokenStore, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.session = session
    }

    static var configuredBaseURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String
        return URL(string: raw ?? "") ?? URL(string: "https://rmillerqa.tech/expense-tracker/api")!
    }

    var hasSession: Bool { tokens.tokens != nil }

    func storeSession(_ newTokens: AuthTokens) { tokens.save(newTokens) }

    func clearSession() { tokens.clear() }

    @discardableResult
    func send<Response: Decodable>(_ endpoint: Endpoint<Response>) async throws -> Response {
        let data = try await perform(endpoint, retryOnUnauthorized: true)
        if Response.self == EmptyResponse.self, let empty = EmptyResponse() as? Response { return empty }
        do {
            return try JSONCoding.decoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Ends the session on the server too. Network errors are ignored: the local session is cleared anyway.
    func logout() async {
        if let refresh = tokens.tokens?.refreshToken {
            _ = try? await perform(API.logout(refresh), retryOnUnauthorized: false)
        }
        tokens.clear()
    }

    private func perform<R>(_ endpoint: Endpoint<R>, retryOnUnauthorized: Bool) async throws -> Data {
        let usedToken = endpoint.requiresAuth ? tokens.tokens?.accessToken : nil
        if endpoint.requiresAuth && usedToken == nil { throw APIError.unauthorized }

        let (data, status) = try await load(makeRequest(endpoint, accessToken: usedToken))

        if status == 401 && endpoint.requiresAuth {
            guard retryOnUnauthorized else {
                expireSession()
                throw APIError.unauthorized
            }
            try await refreshSession(rejectedAccessToken: usedToken)
            return try await perform(endpoint, retryOnUnauthorized: false)
        }
        guard (200..<300).contains(status) else { throw APIError.from(status: status, data: data) }
        return data
    }

    private func refreshSession(rejectedAccessToken: String?) async throws {
        if let running = refreshTask {
            do {
                _ = try await running.value
                return
            } catch let error as APIError where error.isConnectivity {
                throw error
            } catch {
                throw APIError.unauthorized
            }
        }
        // Another request already refreshed while this one was in flight.
        if let current = tokens.tokens?.accessToken, current != rejectedAccessToken { return }
        guard let refreshToken = tokens.tokens?.refreshToken else {
            expireSession()
            throw APIError.unauthorized
        }

        let task = Task { [self] in
            let (data, status) = try await load(makeRequest(API.refresh(refreshToken), accessToken: nil))
            guard (200..<300).contains(status) else { throw APIError.from(status: status, data: data) }
            let newTokens = try JSONCoding.decoder().decode(AuthTokens.self, from: data)
            // Saved here, not after `await task.value`: waiting requests may resume first and must see the new pair.
            tokens.save(newTokens)
            return newTokens
        }
        refreshTask = task
        defer { refreshTask = nil }

        do {
            _ = try await task.value
        } catch let error as APIError where error.isConnectivity {
            throw error
        } catch {
            // 400/401 from /auth/refresh: the refresh token is expired or revoked.
            expireSession()
            throw APIError.unauthorized
        }
    }

    private func expireSession() {
        guard tokens.tokens != nil else { return }
        tokens.clear()
        onSessionExpired?()
    }

    private func makeRequest<R>(_ endpoint: Endpoint<R>, accessToken: String?) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: endpoint.path), resolvingAgainstBaseURL: false)!
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
            // `+` in ISO dates with offsets would be read as a space; our dates end in Z, but be safe.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = endpoint.method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func load(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            return (data, http.statusCode)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.offline
        }
    }
}
