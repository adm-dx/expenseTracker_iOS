import SwiftData
import SwiftUI

struct TransactionFilter: Equatable {
    var type: TransactionType?
    var categoryId: String?
    var tagId: String?

    var isActive: Bool { type != nil || categoryId != nil || tagId != nil }
}

struct TransactionsView: View {
    @Environment(SyncStore.self) private var store
    @Query(sort: \CachedCategory.position) private var categories: [CachedCategory]
    @Query(sort: \CachedTag.name) private var tags: [CachedTag]

    @State private var month = MonthPeriod.current
    @State private var filter = TransactionFilter()
    @State private var editing: CachedTransaction?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            TransactionList(month: month, filter: filter, onSelect: { editing = $0 })
                .safeAreaInset(edge: .top, spacing: 0) {
                    MonthSwitcher(month: $month).background(.bar)
                }
                .navigationTitle("Операции")
                .navigationBarTitleDisplayMode(.inline)
                .offlineIndicator()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { filterMenu }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { isCreating = true } label: { Image(systemName: "plus") }
                            .accessibilityIdentifier("addTransaction")
                            .disabled(categories.isEmpty)
                    }
                }
                .refreshable { await store.sync(month: month) }
                .task(id: "\(month.key)-\(store.displayCurrency)") { await store.sync(month: month) }
                .sheet(isPresented: $isCreating) { TransactionFormView(item: nil) }
                .sheet(item: $editing) { TransactionFormView(item: $0) }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Тип", selection: $filter.type) {
                Text("Все типы").tag(TransactionType?.none)
                ForEach(TransactionType.allCases) { Text($0.title).tag(Optional($0)) }
            }
            Picker("Категория", selection: $filter.categoryId) {
                Text("Все категории").tag(String?.none)
                ForEach(categories) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu)
            Picker("Тег", selection: $filter.tagId) {
                Text("Все теги").tag(String?.none)
                ForEach(tags) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu)
            if filter.isActive {
                Button("Сбросить фильтры", role: .destructive) { filter = TransactionFilter() }
            }
        } label: {
            Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }
}

struct MonthSwitcher: View {
    @Binding var month: MonthPeriod

    var body: some View {
        HStack {
            Button { month = month.adding(months: -1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(month.title).font(.headline)
            Spacer()
            Button { month = month.adding(months: 1) } label: { Image(systemName: "chevron.right") }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// The month's cached transactions; the query follows the month.
private struct TransactionList: View {
    @Environment(SyncStore.self) private var store
    @Query private var items: [CachedTransaction]
    @Query private var categories: [CachedCategory]
    @Query private var tags: [CachedTag]
    let filter: TransactionFilter
    let onSelect: (CachedTransaction) -> Void

    init(month: MonthPeriod, filter: TransactionFilter, onSelect: @escaping (CachedTransaction) -> Void) {
        let start = month.start, next = month.nextStart
        _items = Query(filter: #Predicate { $0.date >= start && $0.date < next },
                       sort: [SortDescriptor(\.date, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)])
        self.filter = filter
        self.onSelect = onSelect
    }

    private var visible: [CachedTransaction] {
        items.filter { item in
            item.syncState != .pendingDelete
                && (filter.type == nil || item.type == filter.type)
                && (filter.categoryId == nil || item.categoryId == filter.categoryId)
                && (filter.tagId == nil || item.tagId == filter.tagId)
        }
    }

    private var days: [(day: Date, items: [CachedTransaction])] {
        let calendar = MonthPeriod.utc
        let groups = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    var body: some View {
        let categoryById = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tagById = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        List {
            Section { totals }
            if let error = store.lastSyncError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
            }
            ForEach(days, id: \.day) { group in
                Section(DayFormat.title(group.day)) {
                    ForEach(group.items) { item in
                        Button { onSelect(item) } label: {
                            TransactionRow(item: item, category: categoryById[item.categoryId],
                                           tag: item.tagId.flatMap { tagById[$0] }, displayCurrency: store.displayCurrency)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Удалить", systemImage: "trash", role: .destructive) { store.deleteTransaction(item) }
                        }
                    }
                }
            }
        }
        .overlay {
            if visible.isEmpty {
                if store.isSyncing {
                    ProgressView("Загрузка…")
                } else {
                    ContentUnavailableView("Нет операций", systemImage: "tray",
                                           description: Text(filter.isActive ? "Попробуйте изменить фильтры" : "Нажмите +, чтобы добавить"))
                }
            }
        }
    }

    private var totals: some View {
        let currency = store.displayCurrency
        var income = Decimal(), expense = Decimal()
        var unconverted = false
        for item in visible {
            let value: Decimal
            if item.convertedCurrency == currency, let converted = item.convertedAmount {
                value = converted
            } else if item.currency == currency {
                value = item.amount
            } else {
                unconverted = true
                continue
            }
            if item.type == .income { income += value } else { expense += value }
        }
        return VStack(spacing: 6) {
            HStack {
                TotalCell(title: "Доходы", value: MoneyFormat.string(income, currency), color: .green)
                TotalCell(title: "Расходы", value: MoneyFormat.string(expense, currency), color: .red)
                TotalCell(title: "Баланс", value: MoneyFormat.string(income - expense, currency), color: .primary)
            }
            if unconverted {
                Text("Без несинхронизированных операций в других валютах")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct TotalCell: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TransactionRow: View {
    let item: CachedTransaction
    let category: CachedCategory?
    let tag: CachedTag?
    let displayCurrency: String

    var body: some View {
        HStack(spacing: 12) {
            CategoryBadge(icon: category?.icon ?? "", color: category?.color ?? "#9CA3AF")
            VStack(alignment: .leading, spacing: 2) {
                Text(category?.name ?? "Без категории").font(.body)
                if let note = item.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let tag {
                    Text("#\(tag.name)").font(.caption2).foregroundStyle(.tint)
                }
                if item.syncState == .failed, let error = item.syncError {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(MoneyFormat.signed(item.amount, item.currency, type: item.type))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(item.type.tint)
                if item.currency != displayCurrency, item.convertedCurrency == displayCurrency, let converted = item.convertedAmount {
                    Text("≈ \(MoneyFormat.string(converted, displayCurrency))").font(.caption2).foregroundStyle(.secondary)
                }
                syncBadge
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var syncBadge: some View {
        switch item.syncState {
        case .pendingCreate, .pendingUpdate, .pendingDelete:
            Image(systemName: "icloud.and.arrow.up").font(.caption2).foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.icloud.fill").font(.caption2).foregroundStyle(.red)
        case .synced:
            EmptyView()
        }
    }
}
