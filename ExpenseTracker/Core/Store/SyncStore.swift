import Foundation
import Observation
import SwiftData

/// Local cache of the user's data plus the sync with the server.
///
/// The server is the source of truth. Only transactions can be changed offline: each local change
/// marks the row as pending, and `sync` sends pending rows in the order they were changed.
/// Categories, tags and settings are changed online only and then re-fetched.
@Observable
final class SyncStore {
    @ObservationIgnored let api: APIClient
    @ObservationIgnored let context: ModelContext

    private(set) var settings: UserSettings?
    private(set) var user: User?
    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncError: String?
    /// Bumped after each sync, so views showing server summaries know to reload.
    private(set) var revision = 0

    @ObservationIgnored private var syncChain: Task<Void, Never>?
    /// Local ids of creates the server is processing right now.
    @ObservationIgnored private var inFlight: Set<String> = []

    var displayCurrency: String { settings?.currency ?? "EUR" }
    var enabledCurrencies: [String] { settings?.currencies ?? ["EUR"] }

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
        settings = cached(UserSettings.self, key: BlobKey.settings)?.value
        user = cached(User.self, key: BlobKey.me)?.value
    }

    // MARK: - Cached server responses

    func cached<T: Decodable>(_ type: T.Type, key: String) -> (value: T, fetchedAt: Date)? {
        var descriptor = FetchDescriptor<CachedBlob>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let blob = try? context.fetch(descriptor).first,
              let value = try? JSONCoding.decoder().decode(T.self, from: blob.data) else { return nil }
        return (value, blob.fetchedAt)
    }

    /// Fetches from the server and keeps the answer for offline use.
    func fetchAndCache<T: Codable>(_ endpoint: Endpoint<T>, key: String) async throws -> T {
        let value = try await api.send(endpoint)
        storeBlob(value, key: key)
        return value
    }

    private func storeBlob<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONCoding.encoder().encode(value) else { return }
        var descriptor = FetchDescriptor<CachedBlob>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let blob = try? context.fetch(descriptor).first {
            blob.data = data
            blob.fetchedAt = .now
        } else {
            context.insert(CachedBlob(key: key, data: data))
        }
        try? context.save()
    }

    // MARK: - Sync

    /// Sends pending changes, refreshes categories, tags and settings, and, when `month` is given,
    /// that month's transactions. Calls run one after another.
    func sync(month: MonthPeriod?, includeReferenceData: Bool = true) async {
        await enqueueSync(month: month, includeReferenceData: includeReferenceData).value
    }

    /// Waits until every queued sync has finished.
    func waitUntilIdle() async {
        await syncChain?.value
    }

    @discardableResult
    private func enqueueSync(month: MonthPeriod?, includeReferenceData: Bool) -> Task<Void, Never> {
        let previous = syncChain
        let task = Task { [self] in
            await previous?.value
            await runSync(month: month, includeReferenceData: includeReferenceData)
        }
        syncChain = task
        return task
    }

    private func runSync(month: MonthPeriod?, includeReferenceData: Bool) async {
        guard api.hasSession else { return }
        isSyncing = true
        defer {
            isSyncing = false
            revision += 1
        }
        do {
            let pushed = try await pushPending()
            if includeReferenceData {
                try await refreshReferenceData()
            } else if pushed {
                // Transaction counts of categories and tags changed.
                try await refreshCategories()
                try await refreshTags()
            }
            if let month { try await pullTransactions(month) }
            lastSyncAt = .now
            lastSyncError = nil
        } catch {
            lastSyncError = APIError.from(error).localizedDescription
        }
    }

    /// Returns whether anything was sent.
    @discardableResult
    func pushPending() async throws -> Bool {
        var sent = false
        // A row can change while its request is in flight, so go round until nothing is left to send.
        for _ in 0..<3 {
            let pending = try pendingTransactions()
            if pending.isEmpty { break }
            for item in pending { try await push(item) }
            sent = true
        }
        return sent
    }

    private func pendingTransactions() throws -> [CachedTransaction] {
        let states = [SyncState.pendingCreate.rawValue, SyncState.pendingUpdate.rawValue, SyncState.pendingDelete.rawValue]
        let descriptor = FetchDescriptor<CachedTransaction>(
            predicate: #Predicate { states.contains($0.syncStateRaw) },
            sortBy: [SortDescriptor(\.modifiedAt)]
        )
        return try context.fetch(descriptor)
    }

    private func push(_ item: CachedTransaction) async throws {
        let operation = item.syncState
        let changedAt = item.modifiedAt
        let localId = item.id
        do {
            switch operation {
            case .pendingCreate:
                inFlight.insert(localId)
                defer { inFlight.remove(localId) }
                let dto = try await api.send(API.createTransaction(item.fields))
                item.id = dto.id
                switch item.syncState {
                case .pendingCreate where item.modifiedAt == changedAt:
                    item.apply(dto, displayCurrency: displayCurrency)
                case .pendingCreate:
                    item.syncState = .pendingUpdate // edited while being created
                default:
                    break // deleted meanwhile: stays pendingDelete and goes out next round
                }
            case .pendingUpdate:
                let dto = try await api.send(API.updateTransaction(id: item.id, item.fields))
                if item.syncState == .pendingUpdate && item.modifiedAt == changedAt {
                    item.apply(dto, displayCurrency: displayCurrency)
                }
            case .pendingDelete:
                try await api.send(API.deleteTransaction(id: item.id))
                context.delete(item)
            case .synced, .failed:
                return
            }
        } catch let error as APIError {
            switch error {
            case .server(404, _) where operation != .pendingCreate:
                context.delete(item) // already gone on the server
            case .server(let status, let message) where (400..<500).contains(status):
                item.failedOperation = operation
                item.syncState = .failed
                item.syncError = message
            default:
                try? context.save()
                throw error // offline, 5xx, expired session: try again later
            }
        }
        try? context.save()
    }

    func pullTransactions(_ month: MonthPeriod) async throws {
        let currency = displayCurrency
        var items: [TransactionDTO] = []
        var page = 1
        while true {
            let response = try await api.send(API.transactions(month, page: page, currency: currency))
            items += response.items
            if response.items.isEmpty || items.count >= response.total { break }
            page += 1
        }

        let ids = items.map(\.id)
        let idSet = Set(ids)
        let start = month.start, next = month.nextStart
        let inMonth = try context.fetch(FetchDescriptor<CachedTransaction>(
            predicate: #Predicate { $0.date >= start && $0.date < next }
        ))
        let known = try context.fetch(FetchDescriptor<CachedTransaction>(predicate: #Predicate { ids.contains($0.id) }))
        let byId = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for dto in items {
            if let existing = byId[dto.id] {
                if existing.syncState == .synced { existing.apply(dto, displayCurrency: currency) }
            } else {
                context.insert(CachedTransaction.from(dto, displayCurrency: currency))
            }
        }
        for item in inMonth where item.syncState == .synced && !idSet.contains(item.id) {
            context.delete(item)
        }
        try context.save()
    }

    func refreshReferenceData() async throws {
        let settings = try await fetchAndCache(API.settings, key: BlobKey.settings)
        self.settings = settings
        user = try await fetchAndCache(API.me, key: BlobKey.me)
        try await refreshCategories()
        try await refreshTags()
    }

    func refreshCategories() async throws {
        let list = try await api.send(API.categories)
        let existing = try context.fetch(FetchDescriptor<CachedCategory>())
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, dto) in list.enumerated() {
            if let item = byId[dto.id] { item.apply(dto, position: index) } else { context.insert(CachedCategory(dto, position: index)) }
        }
        let ids = Set(list.map(\.id))
        for item in existing where !ids.contains(item.id) { context.delete(item) }
        try context.save()
    }

    func refreshTags() async throws {
        let list = try await api.send(API.tags)
        let existing = try context.fetch(FetchDescriptor<CachedTag>())
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for dto in list {
            if let item = byId[dto.id] { item.apply(dto) } else { context.insert(CachedTag(dto)) }
        }
        let ids = Set(list.map(\.id))
        for item in existing where !ids.contains(item.id) { context.delete(item) }
        try context.save()
    }

    // MARK: - Local transaction changes (work offline)

    func saveTransaction(_ fields: TransactionFields, editing item: CachedTransaction?) {
        let target: CachedTransaction
        if let item {
            item.fields = fields
            switch item.syncState {
            case .pendingCreate:
                break
            case .failed:
                item.syncState = item.failedOperation == .pendingCreate ? .pendingCreate : .pendingUpdate
            default:
                item.syncState = .pendingUpdate
            }
            item.failedOperation = nil
            item.syncError = nil
            item.modifiedAt = .now
            target = item
        } else {
            target = CachedTransaction(id: CachedTransaction.localPrefix + UUID().uuidString, fields: fields, state: .pendingCreate)
            context.insert(target)
        }
        // Until the server converts it, only an amount already in the display currency is known.
        target.convertedAmountRaw = fields.currency == displayCurrency ? Money.string(fields.amount) : nil
        target.convertedCurrency = fields.currency == displayCurrency ? displayCurrency : nil
        try? context.save()
        schedulePush()
    }

    func deleteTransaction(_ item: CachedTransaction) {
        let neverReachedServer = item.isLocalOnly && !inFlight.contains(item.id)
            && (item.syncState == .pendingCreate || item.failedOperation == .pendingCreate)
        if neverReachedServer {
            context.delete(item)
        } else {
            item.syncState = .pendingDelete
            item.failedOperation = nil
            item.syncError = nil
            item.modifiedAt = .now
        }
        try? context.save()
        schedulePush()
    }

    /// Sends a rejected change again as it is.
    func retry(_ item: CachedTransaction) {
        guard item.syncState == .failed else { return }
        item.syncState = item.failedOperation ?? .pendingUpdate
        item.failedOperation = nil
        item.syncError = nil
        item.modifiedAt = .now
        try? context.save()
        schedulePush()
    }

    var pendingCount: Int {
        let synced = SyncState.synced.rawValue
        return (try? context.fetchCount(FetchDescriptor<CachedTransaction>(predicate: #Predicate { $0.syncStateRaw != synced }))) ?? 0
    }

    /// Sends local changes in the background (does nothing useful offline; the next sync retries).
    func schedulePush() {
        enqueueSync(month: nil, includeReferenceData: false)
    }

    // MARK: - Online-only changes

    func createCategory(_ body: CreateCategoryBody) async throws {
        try await api.send(API.createCategory(body))
        try await refreshCategories()
    }

    func updateCategory(id: String, _ body: UpdateCategoryBody) async throws {
        try await api.send(API.updateCategory(id: id, body))
        try await refreshCategories()
    }

    func deleteCategory(id: String, reassignTo: String?) async throws {
        try await api.send(API.deleteCategory(id: id, reassignTo: reassignTo))
        if let reassignTo {
            let moved = try context.fetch(FetchDescriptor<CachedTransaction>(predicate: #Predicate { $0.categoryId == id }))
            for item in moved { item.categoryId = reassignTo }
        }
        try await refreshCategories()
        revision += 1
    }

    func createTag(name: String) async throws {
        try await api.send(API.createTag(name: name))
        try await refreshTags()
    }

    func renameTag(id: String, name: String) async throws {
        try await api.send(API.renameTag(id: id, name: name))
        try await refreshTags()
    }

    func deleteTag(id: String) async throws {
        try await api.send(API.deleteTag(id: id))
        let tagged = try context.fetch(FetchDescriptor<CachedTransaction>(predicate: #Predicate { $0.tagId == id }))
        for item in tagged { item.tagId = nil }
        try await refreshTags()
        revision += 1
    }

    func updateSettings(_ body: UpdateSettingsBody) async throws {
        settings = try await fetchAndCache(API.updateSettings(body), key: BlobKey.settings)
    }

    func addCurrency(_ code: String) async throws {
        settings = try await fetchAndCache(API.addCurrency(code), key: BlobKey.settings)
    }

    /// Returns how many transactions the server converted to EUR.
    func removeCurrency(_ code: String) async throws -> Int {
        let result = try await api.send(API.removeCurrency(code))
        settings = result.settings
        storeBlob(result.settings, key: BlobKey.settings)
        return result.convertedCount
    }

    func changePassword(current: String, new: String) async throws {
        let tokens = try await api.send(API.changePassword(current: current, new: new))
        api.storeSession(tokens)
    }

    func setUser(_ user: User) {
        self.user = user
        storeBlob(user, key: BlobKey.me)
    }

    /// Forgets everything cached for the signed-out user.
    func wipe() {
        try? context.delete(model: CachedTransaction.self)
        try? context.delete(model: CachedCategory.self)
        try? context.delete(model: CachedTag.self)
        try? context.delete(model: CachedBlob.self)
        try? context.save()
        settings = nil
        user = nil
        lastSyncAt = nil
        lastSyncError = nil
    }
}

enum BlobKey {
    static let settings = "settings"
    static let me = "me"
    static func summary(_ month: MonthPeriod, _ currency: String) -> String { "summary:\(month.key):\(currency)" }
    static func tagSummary(_ month: MonthPeriod, _ currency: String) -> String { "tags:\(month.key):\(currency)" }
    static func tagHistory(_ tagId: String, _ currency: String) -> String { "tag-history:\(tagId):\(currency)" }
}
