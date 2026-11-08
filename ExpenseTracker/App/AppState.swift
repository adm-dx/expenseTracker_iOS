import Foundation
import Observation
import SwiftData

@Observable
final class AppState {
    enum Phase { case signedOut, signedIn }

    private(set) var phase: Phase
    /// Shown once on the sign-in screen after the server ended the session.
    var sessionExpiredNotice = false

    let api: APIClient
    let store: SyncStore
    let network: NetworkMonitor

    init(container: ModelContainer, tokens: TokenStore = KeychainTokenStore(), session: URLSession = .shared) {
        api = APIClient(baseURL: APIClient.configuredBaseURL, tokens: tokens, session: session)
        store = SyncStore(api: api, context: container.mainContext)
        network = NetworkMonitor()
        // A saved session opens the app straight away, even offline; the server checks it on the first request.
        phase = api.hasSession ? .signedIn : .signedOut

        api.onSessionExpired = { [weak self] in self?.handleSessionExpired() }
        network.onReconnect = { [weak self] in
            guard let self, phase == .signedIn else { return }
            Task { await self.store.sync(month: nil) }
        }
    }

    var isOnline: Bool { network.isOnline }

    func login(email: String, password: String) async throws {
        let response = try await api.send(API.login(email: email.trimmingCharacters(in: .whitespaces), password: password))
        await signIn(response)
    }

    func register(name: String, email: String, password: String) async throws {
        let response = try await api.send(API.register(name: name.trimmingCharacters(in: .whitespaces),
                                                       email: email.trimmingCharacters(in: .whitespaces),
                                                       password: password))
        await signIn(response)
    }

    private func signIn(_ response: AuthResponse) async {
        store.wipe() // the cache may belong to someone else
        api.storeSession(response.tokens)
        store.setUser(response.user)
        sessionExpiredNotice = false
        phase = .signedIn
        await store.sync(month: .current)
    }

    func logout() async {
        await api.logout()
        store.wipe()
        phase = .signedOut
    }

    private func handleSessionExpired() {
        store.wipe()
        sessionExpiredNotice = true
        phase = .signedOut
    }
}
