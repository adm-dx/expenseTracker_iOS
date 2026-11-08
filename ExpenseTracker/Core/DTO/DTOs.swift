import Foundation

// Wire types of the Expense Tracker API, ported from `packages/types/src/index.ts`.
// Money stays a String here (as on the wire); use `Money.parse` to get a Decimal.

nonisolated struct User: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let email: String
    let name: String
    let isActive: Bool
    let lastLoginAt: Date?
    let createdAt: Date
    let updatedAt: Date
}

nonisolated struct AuthTokens: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
}

nonisolated struct AuthResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let user: User

    var tokens: AuthTokens { AuthTokens(accessToken: accessToken, refreshToken: refreshToken) }
}

nonisolated enum TransactionType: String, Codable, Sendable, CaseIterable, Identifiable {
    case income = "INCOME"
    case expense = "EXPENSE"

    var id: String { rawValue }
    var title: String { self == .income ? "Доход" : "Расход" }
}

nonisolated struct TransactionDTO: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let amount: String
    let currency: String
    let type: TransactionType
    let description: String?
    let date: Date
    let categoryId: String
    let tagIds: [String]
    let createdAt: Date
    /// Only in list responses: `amount` in the requested display currency.
    let convertedAmount: String?
}

nonisolated struct TransactionsPage: Codable, Sendable {
    let items: [TransactionDTO]
    let total: Int
    let page: Int
    let pageSize: Int
    let currency: String
    let ratesDate: String?
}

nonisolated struct CategoryDTO: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let color: String
    let icon: String
    let transactionCount: Int
    let createdAt: Date
    let updatedAt: Date
}

nonisolated struct TagDTO: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let transactionCount: Int
    let createdAt: Date
    let updatedAt: Date
}

nonisolated struct CategorySummary: Codable, Sendable, Identifiable, Equatable {
    let categoryId: String
    let name: String
    let color: String
    let icon: String
    let type: TransactionType
    let total: String
    let count: Int

    var id: String { "\(categoryId)-\(type.rawValue)" }
}

nonisolated struct TransactionSummary: Codable, Sendable, Equatable {
    let dateFrom: String
    let dateTo: String
    let totalIncome: String
    let totalExpense: String
    let balance: String
    let byCategory: [CategorySummary]
    let currency: String
    let ratesDate: String?
}

nonisolated struct TagSummary: Codable, Sendable, Identifiable, Equatable {
    let tagId: String?
    let name: String?
    let type: TransactionType
    let total: String
    let count: Int

    var id: String { "\(tagId ?? "none")-\(type.rawValue)" }
}

nonisolated struct TagReport: Codable, Sendable, Equatable {
    let dateFrom: String
    let dateTo: String
    let byTag: [TagSummary]
    let currency: String
    let ratesDate: String?
}

nonisolated struct TagMonthSummary: Codable, Sendable, Identifiable, Equatable {
    /// `YYYY-MM`
    let month: String
    let income: String
    let expense: String
    let incomeCount: Int
    let expenseCount: Int

    var id: String { month }
}

nonisolated struct TagHistoryReport: Codable, Sendable, Equatable {
    let tagId: String
    let totalIncome: String
    let totalExpense: String
    let balance: String
    let byMonth: [TagMonthSummary]
    let currency: String
    let ratesDate: String?
}

nonisolated struct LocationSetting: Codable, Sendable, Equatable {
    let mode: String
    let name: String?
    let lat: Double?
    let lon: Double?
}

nonisolated enum AppTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: "Светлая"
        case .dark: "Тёмная"
        case .system: "Как в системе"
        }
    }
}

nonisolated struct UserSettings: Codable, Sendable, Equatable {
    let theme: AppTheme
    let colorScheme: String
    let currency: String
    let currencies: [String]
    let location: LocationSetting
}

nonisolated struct RemoveCurrencyResult: Codable, Sendable {
    let settings: UserSettings
    let convertedCount: Int
}

/// For endpoints that answer 204 No Content.
nonisolated struct EmptyResponse: Codable, Sendable {}

// MARK: - Request bodies

nonisolated struct LoginBody: Encodable, Sendable { let email: String; let password: String }
nonisolated struct RegisterBody: Encodable, Sendable { let name: String; let email: String; let password: String }
nonisolated struct RefreshBody: Encodable, Sendable { let refreshToken: String }
nonisolated struct ChangePasswordBody: Encodable, Sendable { let currentPassword: String; let newPassword: String }
nonisolated struct NameBody: Encodable, Sendable { let name: String }
nonisolated struct CurrencyCodeBody: Encodable, Sendable { let code: String }

nonisolated struct CreateCategoryBody: Encodable, Sendable {
    let name: String
    let icon: String
    /// `#RRGGBB`; the server picks one when omitted.
    let color: String?
}

nonisolated struct UpdateCategoryBody: Encodable, Sendable {
    let name: String?
    let icon: String?
}

nonisolated struct UpdateSettingsBody: Encodable, Sendable {
    var theme: AppTheme? = nil
    var currency: String? = nil
}

/// The fields of a transaction the user edits. Used for both POST and PATCH.
nonisolated struct TransactionFields: Sendable, Equatable {
    var amount: Decimal
    var currency: String
    var type: TransactionType
    var note: String?
    var date: Date
    var categoryId: String
    var tagId: String?
}

/// `POST /transactions`. Unknown or null fields are rejected by the API, so nils are left out.
nonisolated struct CreateTransactionBody: Encodable, Sendable {
    let fields: TransactionFields

    enum CodingKeys: String, CodingKey { case amount, currency, type, description, date, categoryId, tagIds }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Money.rounded(fields.amount), forKey: .amount)
        try c.encode(fields.currency, forKey: .currency)
        try c.encode(fields.type, forKey: .type)
        if let note = fields.note, !note.isEmpty { try c.encode(note, forKey: .description) }
        try c.encode(fields.date, forKey: .date)
        try c.encode(fields.categoryId, forKey: .categoryId)
        try c.encode(fields.tagId.map { [$0] } ?? [], forKey: .tagIds)
    }
}

/// `PATCH /transactions/:id` with every field; `description: null` clears it, `tagIds: []` clears the tag.
nonisolated struct UpdateTransactionBody: Encodable, Sendable {
    let fields: TransactionFields

    enum CodingKeys: String, CodingKey { case amount, currency, type, description, date, categoryId, tagIds }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Money.rounded(fields.amount), forKey: .amount)
        try c.encode(fields.currency, forKey: .currency)
        try c.encode(fields.type, forKey: .type)
        if let note = fields.note, !note.isEmpty {
            try c.encode(note, forKey: .description)
        } else {
            try c.encodeNil(forKey: .description)
        }
        try c.encode(fields.date, forKey: .date)
        try c.encode(fields.categoryId, forKey: .categoryId)
        try c.encode(fields.tagId.map { [$0] } ?? [], forKey: .tagIds)
    }
}
