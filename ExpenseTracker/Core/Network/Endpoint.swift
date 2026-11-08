import Foundation

nonisolated struct Endpoint<Response: Decodable>: Sendable {
    var method: String
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    var requiresAuth = true

    init(_ method: String, _ path: String, query: [URLQueryItem] = [], requiresAuth: Bool = true) {
        self.method = method
        self.path = path
        self.query = query
        self.requiresAuth = requiresAuth
    }

    init(_ method: String, _ path: String, body: some Encodable, requiresAuth: Bool = true) {
        self.init(method, path, requiresAuth: requiresAuth)
        self.body = try? JSONCoding.encoder().encode(body)
    }
}

/// UTC month helpers: the API's month boundaries are in UTC, and transaction dates are UTC midnights.
nonisolated struct MonthPeriod: Hashable, Sendable {
    let year: Int
    let month: Int

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static var current: MonthPeriod { MonthPeriod(containing: .now) }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(containing date: Date) {
        let parts = Self.utc.dateComponents([.year, .month], from: date)
        self.init(year: parts.year!, month: parts.month!)
    }

    var start: Date { Self.utc.date(from: DateComponents(year: year, month: month, day: 1))! }
    var nextStart: Date { Self.utc.date(byAdding: DateComponents(month: 1), to: start)! }
    /// Last millisecond of the month as the API expects it (its bounds are inclusive).
    /// Written out, because a Date one millisecond earlier can round to .998.
    var endISO: String {
        let lastDay = Self.utc.range(of: .day, in: .month, for: start)!.count
        return String(format: "%04d-%02d-%02dT23:59:59.999Z", year, month, lastDay)
    }

    func adding(months: Int) -> MonthPeriod {
        MonthPeriod(containing: Self.utc.date(byAdding: .month, value: months, to: start)!)
    }

    var key: String { String(format: "%04d-%02d", year, month) }

    var title: String {
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = TimeZone(identifier: "UTC")!
        style.locale = Locale(identifier: "ru_RU")
        let text = start.formatted(style)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Every endpoint the app uses.
nonisolated enum API {
    // Auth
    static func login(email: String, password: String) -> Endpoint<AuthResponse> {
        Endpoint("POST", "/auth/login", body: LoginBody(email: email, password: password), requiresAuth: false)
    }
    static func register(name: String, email: String, password: String) -> Endpoint<AuthResponse> {
        Endpoint("POST", "/auth/register", body: RegisterBody(name: name, email: email, password: password), requiresAuth: false)
    }
    static func refresh(_ token: String) -> Endpoint<AuthTokens> {
        Endpoint("POST", "/auth/refresh", body: RefreshBody(refreshToken: token), requiresAuth: false)
    }
    static func logout(_ token: String) -> Endpoint<EmptyResponse> {
        Endpoint("POST", "/auth/logout", body: RefreshBody(refreshToken: token), requiresAuth: false)
    }
    static func changePassword(current: String, new: String) -> Endpoint<AuthTokens> {
        Endpoint("POST", "/auth/change-password", body: ChangePasswordBody(currentPassword: current, newPassword: new))
    }
    static let me = Endpoint<User>("GET", "/auth/me")

    // Transactions
    static func transactions(_ month: MonthPeriod, page: Int, currency: String) -> Endpoint<TransactionsPage> {
        Endpoint("GET", "/transactions", query: [
            URLQueryItem(name: "dateFrom", value: APIDate.format(month.start)),
            URLQueryItem(name: "dateTo", value: month.endISO),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: "50"),
            URLQueryItem(name: "currency", value: currency),
        ])
    }
    static func createTransaction(_ fields: TransactionFields) -> Endpoint<TransactionDTO> {
        Endpoint("POST", "/transactions", body: CreateTransactionBody(fields: fields))
    }
    static func updateTransaction(id: String, _ fields: TransactionFields) -> Endpoint<TransactionDTO> {
        Endpoint("PATCH", "/transactions/\(id)", body: UpdateTransactionBody(fields: fields))
    }
    static func deleteTransaction(id: String) -> Endpoint<EmptyResponse> {
        Endpoint("DELETE", "/transactions/\(id)")
    }
    static func summary(_ period: MonthPeriod, currency: String) -> Endpoint<TransactionSummary> {
        Endpoint("GET", "/transactions/summary", query: [
            URLQueryItem(name: "month", value: String(period.month)),
            URLQueryItem(name: "year", value: String(period.year)),
            URLQueryItem(name: "currency", value: currency),
        ])
    }
    static func tagSummary(_ period: MonthPeriod, currency: String) -> Endpoint<TagReport> {
        Endpoint("GET", "/transactions/summary/by-tag", query: [
            URLQueryItem(name: "dateFrom", value: APIDate.format(period.start)),
            URLQueryItem(name: "dateTo", value: period.endISO),
            URLQueryItem(name: "currency", value: currency),
        ])
    }
    static func tagHistory(tagId: String, currency: String) -> Endpoint<TagHistoryReport> {
        Endpoint("GET", "/transactions/summary/by-tag/history", query: [
            URLQueryItem(name: "tagId", value: tagId),
            URLQueryItem(name: "currency", value: currency),
        ])
    }

    // Categories
    static let categories = Endpoint<[CategoryDTO]>("GET", "/categories")
    static func createCategory(_ body: CreateCategoryBody) -> Endpoint<CategoryDTO> {
        Endpoint("POST", "/categories", body: body)
    }
    static func updateCategory(id: String, _ body: UpdateCategoryBody) -> Endpoint<CategoryDTO> {
        Endpoint("PATCH", "/categories/\(id)", body: body)
    }
    static func deleteCategory(id: String, reassignTo: String?) -> Endpoint<EmptyResponse> {
        Endpoint("DELETE", "/categories/\(id)", query: reassignTo.map { [URLQueryItem(name: "reassignTo", value: $0)] } ?? [])
    }

    // Tags
    static let tags = Endpoint<[TagDTO]>("GET", "/tags")
    static func createTag(name: String) -> Endpoint<TagDTO> { Endpoint("POST", "/tags", body: NameBody(name: name)) }
    static func renameTag(id: String, name: String) -> Endpoint<TagDTO> { Endpoint("PATCH", "/tags/\(id)", body: NameBody(name: name)) }
    static func deleteTag(id: String) -> Endpoint<EmptyResponse> { Endpoint("DELETE", "/tags/\(id)") }

    // Settings
    static let settings = Endpoint<UserSettings>("GET", "/settings")
    static func updateSettings(_ body: UpdateSettingsBody) -> Endpoint<UserSettings> {
        Endpoint("PATCH", "/settings", body: body)
    }
    static func addCurrency(_ code: String) -> Endpoint<UserSettings> {
        Endpoint("POST", "/settings/currencies", body: CurrencyCodeBody(code: code))
    }
    static func removeCurrency(_ code: String) -> Endpoint<RemoveCurrencyResult> {
        Endpoint("DELETE", "/settings/currencies/\(code)")
    }
}
