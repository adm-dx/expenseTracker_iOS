import Charts
import SwiftData
import SwiftUI

/// A server report plus where it came from: fresh, or the last cached copy when offline.
struct Loaded<T> {
    var value: T?
    var fetchedAt: Date?
    var isStale = false
    var error: String?
}

extension SyncStore {
    /// Shows the cached copy first, then replaces it with a fresh one when the server answers.
    func load<T: Codable>(_ endpoint: Endpoint<T>, key: String, into state: Binding<Loaded<T>>) async {
        if let cached = cached(T.self, key: key) {
            state.wrappedValue = Loaded(value: cached.value, fetchedAt: cached.fetchedAt, isStale: true)
        } else {
            state.wrappedValue = Loaded()
        }
        do {
            let fresh = try await fetchAndCache(endpoint, key: key)
            state.wrappedValue = Loaded(value: fresh, fetchedAt: .now)
        } catch {
            state.wrappedValue.error = APIError.from(error).localizedDescription
        }
    }
}

struct StaleNotice: View {
    let fetchedAt: Date?
    let error: String?

    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 2) {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                if let fetchedAt {
                    Text("Показаны данные на \(DayFormat.short(fetchedAt))").foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
        }
    }
}

struct SummaryView: View {
    enum Mode: String, CaseIterable { case categories = "Категории", tags = "Теги" }

    @Environment(SyncStore.self) private var store
    @State private var month = MonthPeriod.current
    @State private var mode: Mode = .categories

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .categories: CategorySummaryView(month: month)
                case .tags: TagSummaryView(month: month)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    MonthSwitcher(month: $month)
                    Picker("Разрез", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .padding([.horizontal, .bottom])
                }
                .background(.bar)
            }
            .navigationTitle("Сводка")
            .navigationBarTitleDisplayMode(.inline)
            .offlineIndicator()
        }
    }
}

private struct CategorySummaryView: View {
    @Environment(SyncStore.self) private var store
    let month: MonthPeriod
    @State private var state = Loaded<TransactionSummary>()
    @State private var type: TransactionType = .expense

    var body: some View {
        List {
            if state.error != nil {
                Section { StaleNotice(fetchedAt: state.fetchedAt, error: state.error) }
            }
            if let summary = state.value {
                Section {
                    HStack {
                        TotalCell(title: "Доходы", value: MoneyFormat.string(Money.parse(summary.totalIncome), summary.currency), color: .green)
                        TotalCell(title: "Расходы", value: MoneyFormat.string(Money.parse(summary.totalExpense), summary.currency), color: .red)
                        TotalCell(title: "Баланс", value: MoneyFormat.string(Money.parse(summary.balance), summary.currency), color: .primary)
                    }
                }

                let rows = summary.byCategory.filter { $0.type == type }.sorted { Money.parse($0.total) > Money.parse($1.total) }
                let sum = rows.reduce(Decimal()) { $0 + Money.parse($1.total) }

                Section {
                    Picker("Тип", selection: $type) {
                        ForEach(TransactionType.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if rows.isEmpty {
                        Text("Нет операций за месяц").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        Chart(rows) { row in
                            SectorMark(angle: .value("Сумма", NSDecimalNumber(decimal: Money.parse(row.total)).doubleValue),
                                       innerRadius: .ratio(0.6), angularInset: 1.5)
                                .cornerRadius(4)
                                .foregroundStyle(Color(hex: row.color))
                        }
                        .chartBackground { _ in
                            VStack {
                                Text(type == .expense ? "Расходы" : "Доходы").font(.caption).foregroundStyle(.secondary)
                                Text(MoneyFormat.string(sum, summary.currency)).font(.headline)
                            }
                        }
                        .frame(height: 240)
                        .padding(.vertical, 8)
                    }
                }

                Section {
                    ForEach(rows) { row in
                        let total = Money.parse(row.total)
                        HStack(spacing: 12) {
                            CategoryBadge(icon: row.icon, color: row.color, size: 32)
                            VStack(alignment: .leading) {
                                Text(row.name)
                                Text("\(row.count) опер.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(MoneyFormat.string(total, summary.currency)).font(.body.weight(.semibold))
                                if sum > 0 {
                                    Text(percent(total, of: sum)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    if let ratesDate = summary.ratesDate {
                        Text("Пересчёт в \(summary.currency) по курсу на \(ratesDate.prefix(10))")
                    }
                }
            } else if state.error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .refreshable { await reload() }
        .task(id: "\(month.key)-\(store.displayCurrency)-\(store.revision)") { await reload() }
    }

    private func reload() async {
        await store.load(API.summary(month, currency: store.displayCurrency),
                         key: BlobKey.summary(month, store.displayCurrency), into: $state)
    }
}

func percent(_ part: Decimal, of whole: Decimal) -> String {
    let value = NSDecimalNumber(decimal: part / whole).doubleValue
    return value.formatted(.percent.precision(.fractionLength(0...1)).locale(Locale(identifier: "ru_RU")))
}

private struct TagSummaryView: View {
    @Environment(SyncStore.self) private var store
    let month: MonthPeriod
    @State private var state = Loaded<TagReport>()

    private struct Row: Identifiable {
        let id: String
        let tagId: String?
        let name: String
        var income = Decimal()
        var expense = Decimal()
        var count = 0
    }

    var body: some View {
        List {
            if state.error != nil {
                Section { StaleNotice(fetchedAt: state.fetchedAt, error: state.error) }
            }
            if let report = state.value {
                let rows = rows(report)
                if rows.isEmpty {
                    Text("Нет операций за месяц").foregroundStyle(.secondary)
                }
                Section {
                    ForEach(rows) { row in
                        let content = HStack {
                            VStack(alignment: .leading) {
                                Text(row.tagId == nil ? "Без тега" : "#\(row.name)")
                                Text("\(row.count) опер.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                if row.income > 0 {
                                    Text("+" + MoneyFormat.string(row.income, report.currency)).foregroundStyle(.green)
                                }
                                if row.expense > 0 {
                                    Text("−" + MoneyFormat.string(row.expense, report.currency))
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        if let tagId = row.tagId {
                            NavigationLink { TagHistoryView(tagId: tagId, name: row.name) } label: { content }
                        } else {
                            content
                        }
                    }
                } footer: {
                    Text("Нажмите на тег, чтобы увидеть историю по месяцам.")
                }
            } else if state.error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .refreshable { await reload() }
        .task(id: "\(month.key)-\(store.displayCurrency)-\(store.revision)") { await reload() }
    }

    private func rows(_ report: TagReport) -> [Row] {
        var byTag: [String: Row] = [:]
        for item in report.byTag {
            let key = item.tagId ?? "none"
            var row = byTag[key] ?? Row(id: key, tagId: item.tagId, name: item.name ?? "")
            if item.type == .income { row.income += Money.parse(item.total) } else { row.expense += Money.parse(item.total) }
            row.count += item.count
            byTag[key] = row
        }
        return byTag.values.sorted { lhs, rhs in
            if (lhs.tagId == nil) != (rhs.tagId == nil) { return rhs.tagId == nil }
            return lhs.expense + lhs.income > rhs.expense + rhs.income
        }
    }

    private func reload() async {
        await store.load(API.tagSummary(month, currency: store.displayCurrency),
                         key: BlobKey.tagSummary(month, store.displayCurrency), into: $state)
    }
}

struct TagHistoryView: View {
    @Environment(SyncStore.self) private var store
    let tagId: String
    let name: String
    @State private var state = Loaded<TagHistoryReport>()

    private struct Bar: Identifiable {
        let id: String
        let month: Date
        let type: String
        let value: Double
    }

    var body: some View {
        List {
            if state.error != nil {
                Section { StaleNotice(fetchedAt: state.fetchedAt, error: state.error) }
            }
            if let report = state.value {
                Section {
                    HStack {
                        TotalCell(title: "Доходы", value: MoneyFormat.string(Money.parse(report.totalIncome), report.currency), color: .green)
                        TotalCell(title: "Расходы", value: MoneyFormat.string(Money.parse(report.totalExpense), report.currency), color: .red)
                        TotalCell(title: "Баланс", value: MoneyFormat.string(Money.parse(report.balance), report.currency), color: .primary)
                    }
                }
                if !report.byMonth.isEmpty {
                    Section("По месяцам") {
                        Chart(bars(report)) { bar in
                            BarMark(x: .value("Месяц", bar.month, unit: .month), y: .value("Сумма", bar.value))
                                .foregroundStyle(by: .value("Тип", bar.type))
                                .position(by: .value("Тип", bar.type))
                        }
                        .chartForegroundStyleScale(["Доходы": Color.green, "Расходы": Color.red])
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .month)) { _ in
                                AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                            }
                        }
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                        .frame(height: 220)
                        .padding(.vertical, 8)

                        ForEach(report.byMonth.reversed()) { month in
                            HStack {
                                Text(monthTitle(month.month))
                                Spacer()
                                VStack(alignment: .trailing) {
                                    if Money.parse(month.income) > 0 {
                                        Text("+" + MoneyFormat.string(Money.parse(month.income), report.currency)).foregroundStyle(.green)
                                    }
                                    Text("−" + MoneyFormat.string(Money.parse(month.expense), report.currency))
                                }
                                .font(.subheadline)
                            }
                        }
                    }
                }
            } else if state.error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("#\(name)")
        .task(id: store.displayCurrency) {
            await store.load(API.tagHistory(tagId: tagId, currency: store.displayCurrency),
                             key: BlobKey.tagHistory(tagId, store.displayCurrency), into: $state)
        }
    }

    private func monthDate(_ key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return .now }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) ?? .now
    }

    private func monthTitle(_ key: String) -> String {
        let text = monthDate(key).formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "ru_RU")))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private func bars(_ report: TagHistoryReport) -> [Bar] {
        report.byMonth.flatMap { month in
            [
                Bar(id: month.month + "i", month: monthDate(month.month), type: "Доходы",
                    value: NSDecimalNumber(decimal: Money.parse(month.income)).doubleValue),
                Bar(id: month.month + "e", month: monthDate(month.month), type: "Расходы",
                    value: NSDecimalNumber(decimal: Money.parse(month.expense)).doubleValue),
            ]
        }
    }
}
