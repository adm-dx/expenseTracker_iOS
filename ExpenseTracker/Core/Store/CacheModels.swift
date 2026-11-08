import Foundation
import SwiftData

/// Where a cached transaction stands relative to the server.
enum SyncState: String, Codable {
    case synced
    /// Made offline; has a local id until the server accepts it.
    case pendingCreate
    case pendingUpdate
    /// Hidden in the UI; removed for good once the server confirms.
    case pendingDelete
    /// The server rejected the change (400/409). `failedOperation` says which one.
    case failed
}

@Model
final class CachedTransaction {
    @Attribute(.unique) var id: String
    var amountRaw: String
    var currency: String
    var typeRaw: String
    var note: String?
    var date: Date
    var categoryId: String
    var tagId: String?
    var createdAt: Date
    /// `amount` in `convertedCurrency`, as the server computed it.
    var convertedAmountRaw: String?
    var convertedCurrency: String?
    var syncStateRaw: String
    var failedOperationRaw: String?
    var syncError: String?
    /// When the user last changed it locally; pending changes are sent in this order.
    var modifiedAt: Date

    init(id: String, fields: TransactionFields, createdAt: Date = .now, state: SyncState) {
        self.id = id
        amountRaw = Money.string(fields.amount)
        currency = fields.currency
        typeRaw = fields.type.rawValue
        note = fields.note
        date = fields.date
        categoryId = fields.categoryId
        tagId = fields.tagId
        self.createdAt = createdAt
        syncStateRaw = state.rawValue
        modifiedAt = .now
    }

    var amount: Decimal { Money.parse(amountRaw) }
    var type: TransactionType { TransactionType(rawValue: typeRaw) ?? .expense }
    var convertedAmount: Decimal? { convertedAmountRaw.map(Money.parse) }

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .synced }
        set { syncStateRaw = newValue.rawValue }
    }

    var failedOperation: SyncState? {
        get { failedOperationRaw.flatMap(SyncState.init(rawValue:)) }
        set { failedOperationRaw = newValue?.rawValue }
    }

    var isLocalOnly: Bool { id.hasPrefix(Self.localPrefix) }
    var isPending: Bool { syncState != .synced }

    static let localPrefix = "local-"

    var fields: TransactionFields {
        get {
            TransactionFields(amount: amount, currency: currency, type: type, note: note, date: date,
                              categoryId: categoryId, tagId: tagId)
        }
        set {
            amountRaw = Money.string(newValue.amount)
            currency = newValue.currency
            typeRaw = newValue.type.rawValue
            note = newValue.note
            date = newValue.date
            categoryId = newValue.categoryId
            tagId = newValue.tagId
        }
    }

    func apply(_ dto: TransactionDTO, displayCurrency: String) {
        amountRaw = dto.amount
        currency = dto.currency
        typeRaw = dto.type.rawValue
        note = dto.description
        date = dto.date
        categoryId = dto.categoryId
        tagId = dto.tagIds.first
        createdAt = dto.createdAt
        if let converted = dto.convertedAmount {
            convertedAmountRaw = converted
            convertedCurrency = displayCurrency
        } else if dto.currency == displayCurrency {
            convertedAmountRaw = dto.amount
            convertedCurrency = displayCurrency
        } else {
            convertedAmountRaw = nil
            convertedCurrency = nil
        }
        syncState = .synced
        failedOperation = nil
        syncError = nil
    }

    static func from(_ dto: TransactionDTO, displayCurrency: String) -> CachedTransaction {
        let fields = TransactionFields(amount: Money.parse(dto.amount), currency: dto.currency, type: dto.type,
                                       note: dto.description, date: dto.date, categoryId: dto.categoryId,
                                       tagId: dto.tagIds.first)
        let item = CachedTransaction(id: dto.id, fields: fields, createdAt: dto.createdAt, state: .synced)
        item.apply(dto, displayCurrency: displayCurrency)
        return item
    }
}

@Model
final class CachedCategory {
    @Attribute(.unique) var id: String
    var name: String
    var color: String
    var icon: String
    var transactionCount: Int
    /// Keeps the server's order.
    var position: Int

    init(_ dto: CategoryDTO, position: Int) {
        id = dto.id
        name = dto.name
        color = dto.color
        icon = dto.icon
        transactionCount = dto.transactionCount
        self.position = position
    }

    func apply(_ dto: CategoryDTO, position: Int) {
        name = dto.name
        color = dto.color
        icon = dto.icon
        transactionCount = dto.transactionCount
        self.position = position
    }
}

@Model
final class CachedTag {
    @Attribute(.unique) var id: String
    var name: String
    var transactionCount: Int

    init(_ dto: TagDTO) {
        id = dto.id
        name = dto.name
        transactionCount = dto.transactionCount
    }

    func apply(_ dto: TagDTO) {
        name = dto.name
        transactionCount = dto.transactionCount
    }
}

/// Any server response kept as JSON: settings, profile, summaries.
@Model
final class CachedBlob {
    @Attribute(.unique) var key: String
    var data: Data
    var fetchedAt: Date

    init(key: String, data: Data) {
        self.key = key
        self.data = data
        fetchedAt = .now
    }
}

enum CacheSchema {
    static let models: [any PersistentModel.Type] = [
        CachedTransaction.self, CachedCategory.self, CachedTag.self, CachedBlob.self,
    ]

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: Schema(models), configurations: configuration)
        } catch {
            // The cache can always be rebuilt from the server.
            let url = configuration.url
            try? FileManager.default.removeItem(at: url)
            return try! ModelContainer(for: Schema(models), configurations: configuration)
        }
    }
}
