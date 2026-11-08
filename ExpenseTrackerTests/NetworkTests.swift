import Foundation
import SwiftData
import Testing
@testable import ExpenseTracker

/// All tests that go through `MockURLProtocol` share its handler, so they run one at a time.
@Suite(.serialized)
struct NetworkTests {
    let baseURL = URL(string: "https://example.test/api")!
    /// SwiftData crashes if a container is freed while its context is in use, so each test keeps its own.
    let container = CacheSchema.makeContainer(inMemory: true)

    private func makeClient(_ tokens: TokenStore) -> APIClient {
        APIClient(baseURL: baseURL, tokens: tokens, session: MockURLProtocol.session())
    }

    private func makeStore() -> (SyncStore, ModelContext) {
        let client = makeClient(InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r")))
        return (SyncStore(api: client, context: container.mainContext), container.mainContext)
    }

    private func all(_ context: ModelContext) -> [CachedTransaction] {
        (try? context.fetch(FetchDescriptor<CachedTransaction>())) ?? []
    }

    // MARK: Session

    @Test func concurrentRequestsShareOneRefresh() async throws {
        let tokens = InMemoryTokenStore(AuthTokens(accessToken: "old", refreshToken: "r1"))
        let client = makeClient(tokens)
        MockURLProtocol.setHandler { request, body in
            switch request.url!.path {
            case "/api/auth/refresh":
                #expect(Fixture.json(body)["refreshToken"] as? String == "r1")
                return .init(status: 200, body: #"{"accessToken":"new","refreshToken":"r2"}"#)
            case "/api/tags":
                let ok = request.value(forHTTPHeaderField: "Authorization") == "Bearer new"
                return ok ? .init(status: 200, body: "[]") : .init(status: 401, body: #"{"statusCode":401,"message":"Unauthorized"}"#)
            default:
                return .init(status: 404, body: "{}")
            }
        }

        async let first = client.send(API.tags)
        async let second = client.send(API.tags)
        async let third = client.send(API.tags)
        _ = try await (first, second, third)

        let refreshes = MockURLProtocol.requests.filter { $0.path == "/api/auth/refresh" }
        #expect(refreshes.count == 1)
        #expect(tokens.tokens == AuthTokens(accessToken: "new", refreshToken: "r2"))
    }

    @Test func rejectedRefreshEndsSession() async {
        let tokens = InMemoryTokenStore(AuthTokens(accessToken: "old", refreshToken: "revoked"))
        let client = makeClient(tokens)
        var expired = false
        client.onSessionExpired = { expired = true }
        MockURLProtocol.setHandler { _, _ in .init(status: 401, body: #"{"statusCode":401,"message":"Unauthorized"}"#) }

        await #expect(throws: APIError.unauthorized) { try await client.send(API.tags) }
        #expect(expired)
        #expect(tokens.tokens == nil)
    }

    @Test func networkFailureKeepsSession() async {
        let tokens = InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r"))
        // No server at all: a real session to an unroutable address.
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, tokens: tokens)
        await #expect(throws: APIError.offline) { try await client.send(API.tags) }
        #expect(tokens.tokens != nil)
    }

    // MARK: Sync

    @Test func offlineCreateIsSentAndTakesServerId() async throws {
        let (store, context) = makeStore()
        MockURLProtocol.setHandler { request, body in
            guard request.httpMethod == "POST", request.url!.path == "/api/transactions" else { return .init(status: 500, body: "{}") }
            let sent = Fixture.json(body)
            #expect(sent["categoryId"] as? String == "cat-1")
            #expect(sent["description"] == nil)
            return .init(status: 201, body: Fixture.transaction(id: "server-1", description: nil))
        }
        let fields = TransactionFields(amount: 12.5, currency: "EUR", type: .expense, note: nil,
                                       date: APIDate.parse("2026-11-08T00:00:00.000Z")!, categoryId: "cat-1", tagId: nil)
        store.saveTransaction(fields, editing: nil)
        #expect(all(context).first?.syncState == .pendingCreate)

        await store.sync(month: nil, includeReferenceData: false)

        let items = all(context)
        #expect(items.count == 1)
        #expect(items.first?.id == "server-1")
        #expect(items.first?.syncState == .synced)
        #expect(MockURLProtocol.requests.filter { $0.method == "POST" }.count == 1)
        await store.waitUntilIdle()
    }

    @Test func rejectedChangeIsMarkedFailedAndCanBeRetried() async throws {
        let (store, context) = makeStore()
        MockURLProtocol.setHandler { _, _ in
            .init(status: 400, body: #"{"statusCode":400,"message":"Currency USD is not enabled"}"#)
        }
        let fields = TransactionFields(amount: 3, currency: "USD", type: .expense, note: nil, date: .now, categoryId: "cat-1", tagId: nil)
        store.saveTransaction(fields, editing: nil)
        await store.sync(month: nil, includeReferenceData: false)

        let item = try #require(all(context).first)
        #expect(item.syncState == .failed)
        #expect(item.failedOperation == .pendingCreate)
        #expect(item.syncError == "Currency USD is not enabled")

        store.retry(item)
        #expect(item.syncState == .pendingCreate)
        await store.waitUntilIdle()
    }

    @Test func deletingUnsentTransactionNeedsNoRequest() async {
        let (store, context) = makeStore()
        MockURLProtocol.setHandler { _, _ in .init(status: 500, body: "{}") }
        store.saveTransaction(TransactionFields(amount: 1, currency: "EUR", type: .expense, note: nil, date: .now,
                                                categoryId: "c", tagId: nil), editing: nil)
        // Deleted before the background push gets to it.
        let item = all(context)[0]
        store.deleteTransaction(item)
        #expect(all(context).isEmpty)
        await store.waitUntilIdle()
    }

    @Test func deleteOfMissingTransactionIsDropped() async {
        let (store, context) = makeStore()
        let item = CachedTransaction.from(try! JSONCoding.decoder().decode(TransactionDTO.self, from: Data(Fixture.transaction(id: "gone").utf8)),
                                          displayCurrency: "EUR")
        context.insert(item)
        MockURLProtocol.setHandler { _, _ in .init(status: 404, body: #"{"statusCode":404,"message":"Not found"}"#) }

        store.deleteTransaction(item)
        await store.sync(month: nil, includeReferenceData: false)
        #expect(all(context).isEmpty)
        await store.waitUntilIdle()
    }

    @Test func pullReplacesSyncedRowsAndKeepsPendingOnes() async throws {
        let (store, context) = makeStore()
        let decoder = JSONCoding.decoder()
        let stale = CachedTransaction.from(try decoder.decode(TransactionDTO.self, from: Data(Fixture.transaction(id: "stale").utf8)), displayCurrency: "EUR")
        let edited = CachedTransaction.from(try decoder.decode(TransactionDTO.self, from: Data(Fixture.transaction(id: "edited").utf8)), displayCurrency: "EUR")
        context.insert(stale)
        context.insert(edited)
        edited.note = "local edit"
        edited.syncState = .pendingUpdate

        MockURLProtocol.setHandler { request, _ in
            switch (request.httpMethod, request.url!.path) {
            case ("PATCH", "/api/transactions/edited"):
                return .init(status: 503, body: "{}") // server down: the edit stays pending
            case ("GET", "/api/transactions"):
                return .init(status: 200, body: Fixture.page([
                    Fixture.transaction(id: "edited", description: "server copy"),
                    Fixture.transaction(id: "fresh", amount: "100.00", currency: "USD", converted: "86.20"),
                ]))
            default:
                return .init(status: 500, body: "{}")
            }
        }

        // Push fails with 503, so pull directly to check the merge.
        try await store.pullTransactions(MonthPeriod(year: 2026, month: 11))

        let byId = Dictionary(uniqueKeysWithValues: all(context).map { ($0.id, $0) })
        #expect(byId["stale"] == nil)
        #expect(byId["edited"]?.note == "local edit")
        #expect(byId["fresh"]?.convertedAmount == Decimal(string: "86.2"))
        #expect(byId["fresh"]?.convertedCurrency == "EUR")
        await store.waitUntilIdle()
    }
}
